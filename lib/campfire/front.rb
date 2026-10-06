# frozen_string_literal: true

require "zlib"
require "openssl"
require "protocol/http/response"
require "protocol/http/headers"
require "protocol/http/body/buffered"
require "protocol/http/body/readable"

module Campfire
  # The response layers between the app and the wire, matching what the Rails
  # reference sends from behind Thruster (spec: ref-rust crates/kit/src/front,
  # deflater.rs, ctx.rs#finish):
  #
  #   Thruster (cache, `X-Cache`, `Vary: Accept-Encoding`)  -> Front.call
  #     Rack::Deflater (config.ru)                          -> Front.deflate
  #       ActionDispatch::Static                            -> App#static
  #       Rack::ETag / ConditionalGet, default headers      -> Front.rails!
  #
  # Header fields are plain [name, value] Arrays (lowercase names) mutated in
  # place before Protocol::HTTP::Headers indexes them; every name and fixed
  # value is a frozen constant.
  module Front
    CACHE_CONTROL = "cache-control"
    CONTENT_TYPE = "content-type"
    CONTENT_LENGTH = "content-length"
    CONTENT_ENCODING = "content-encoding"
    ETAG = "etag"
    LAST_MODIFIED = "last-modified"
    SET_COOKIE = "set-cookie"
    VARY = "vary"
    X_CACHE = "x-cache"
    GZIP = "gzip"
    HIT = "hit"
    MISS = "miss"
    BYPASS = "bypass"
    ACCEPT_ENCODING = "Accept-Encoding"
    ACCEPT = "Accept"
    HTML_UTF8 = "text/html; charset=utf-8"
    # ActionDispatch::PublicExceptions writes this exact type; responses carrying it are
    # exception pages, which skip the controller's headers (see Controller#finish).
    PUBLIC_ERROR_TYPE = "text/html; charset=UTF-8"
    NO_CACHE = "no-cache"
    REVALIDATE = "max-age=0, private, must-revalidate"
    # Internal marker: the app set `Content-Length: 0` itself, so Rack::Deflater leaves the
    # response alone. Never sent.
    NO_DEFLATE = "x-campfire-no-deflate"

    # config.action_dispatch.default_headers (load_defaults 7.1).
    DEFAULT_HEADERS = [
      ["x-frame-options", "SAMEORIGIN"],
      ["x-xss-protection", "0"],
      ["x-content-type-options", "nosniff"],
      ["x-permitted-cross-domain-policies", "none"],
      ["referrer-policy", "strict-origin-when-cross-origin"]
    ].freeze

    EMPTY_GZIP = Zlib.gzip("").freeze
    # Thruster's limits: the longest cacheable path+query, the largest cached response, and
    # the cache's capacity (split across the worker Ractors, each of which has its own).
    MAX_CACHEABLE_URI = 2048
    MAX_CACHE_ITEM = 1 << 20
    CACHE_SIZE = (ENV["CACHE_SIZE"]&.to_i || (64 << 20))
    ENTRY_OVERHEAD = 256
    # Bodies at most this long are read whole to gzip (and cache); longer ones stream.
    MAX_BUFFERED_GZIP = 1 << 20

    Entry = Struct.new(:status, :fields, :body, :variant, :expires_at, :size)

    # Thruster's MemoryCache, one per worker Ractor: insertion-ordered Hash used as an LRU,
    # bounded by bytes, entries expiring with their max-age.
    class Cache
      attr_reader :size

      def initialize(capacity)
        @capacity = capacity
        @size = 0
        @items = {}
      end

      def get(key, now)
        entry = @items[key] or return nil
        if entry.expires_at < now
          @items.delete(key)
          @size -= entry.size
          return nil
        end
        @items.delete(key)
        @items[key] = entry # most recently used last
        entry
      end

      def set(key, entry)
        return if entry.size > MAX_CACHE_ITEM || entry.size > @capacity
        if (old = @items.delete(key))
          @size -= old.size
        end
        while @size + entry.size > @capacity && (oldest = @items.each_key { |k| break k })
          @size -= @items.delete(oldest).size
        end
        @items[key] = entry
        @size += entry.size
      end

      def length = @items.size
    end

    module_function

    def cache
      Ractor.current[:front_cache] ||= begin
        workers = (Campfire.config.workers rescue 1).to_i
        Cache.new(CACHE_SIZE / (workers < 1 ? 1 : workers))
      end
    end

    # ActionController's _set_vary_header (every `render`): `Vary: Accept` when the format
    # came from the Accept header: no :format param, and an Accept that isn't a browser's
    # (`,*/*` or `*/*,`), or an XHR with an Accept or Content-Type.
    def vary_accept?(request, format)
      return false if format
      accept = request.headers["accept"]&.to_s
      present = accept && !accept.strip.empty?
      xhr = request.headers["x-requested-with"]&.to_s == "XMLHttpRequest"
      return true if xhr && (present || !(request.headers["content-type"]&.to_s || "").empty?)
      present && !accept.match?(BROWSER_LIKE_ACCEPTS)
    end
    BROWSER_LIKE_ACCEPTS = /,\s*\*\/\*|\*\/\*\s*,/

    # ---- Thruster ----------------------------------------------------------

    def call(app, request)
      verb = request.method
      head = verb == "HEAD"
      if (verb == "GET" || head) && cacheable_request?(request)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        key = base_key(request)
        store = cache
        entry = store.get(key, now)
        if entry && entry.variant && !variant_matches?(entry.variant, request)
          key = variant_key(key, entry.variant, request)
          entry = store.get(key, now)
        end
        return hit(entry, request) if entry

        response = deflate(request, app.call(request))
        fields = response.headers.to_a
        status = response.status
        lifetime = cache_lifetime(status, fields)
        delete_field(fields, SET_COOKIE) if lifetime
        fields << [X_CACHE, MISS]
        fields << [VARY, ACCEPT_ENCODING] unless field(fields, VARY)
        suppress_bodiless(status, fields)
        response = record(response, store, key, request, status, fields, now + lifetime) if lifetime
        response
      else
        response = deflate(request, app.call(request))
        fields = response.headers.to_a
        fields << [X_CACHE, BYPASS]
        fields << [VARY, ACCEPT_ENCODING]
        suppress_bodiless(response.status, fields)
        response
      end
    end

    # shouldCacheRequest: not an upgrade, not a range, not a very long URI.
    def cacheable_request?(request)
      headers = request.headers
      return false if headers["upgrade"]&.to_s == "websocket" || headers["connection"]&.to_s == "Upgrade"
      return false if (r = headers["range"]) && !r.to_s.empty?
      request.path.bytesize <= MAX_CACHEABLE_URI
    end

    def base_key(request)
      key = String.new(request.method, capacity: request.path.bytesize + 48)
      key << "\n" << request.path << "\n"
      key << (request.authority || request.headers["host"]&.to_s || "")
    end

    def variant_key(key, variant, request)
      key = key.dup
      variant.each { |name, _| key << "\n" << name << "=" << (request.headers[name]&.to_s || "") }
      key
    end

    def variant_matches?(variant, request)
      variant.all? { |name, value| (request.headers[name]&.to_s || "") == value }
    end

    # CacheStatus: 2xx/3xx (not 304) saying `public` with a positive s-max-age or max-age,
    # without no-cache or `Vary: *`. Returns the lifetime in seconds, or nil.
    def cache_lifetime(status, fields)
      return nil if status < 200 || status > 399 || status == 304
      vary = field(fields, VARY)
      return nil if vary&.include?("*")
      cc = field(fields, CACHE_CONTROL) or return nil
      return nil unless cc.match?(/\bpublic\b/) && !cc.match?(/\bno-cache\b/)
      m = cc.match(/\bs-max-age=(\d+)\b/) || cc.match(/\bmax-age=(\d+)\b/) or return nil
      seconds = m[1].to_i
      seconds > 0 ? seconds : nil
    end

    # Stores a cacheable response (its body read whole if it fits the item limit).
    def record(response, store, key, request, status, fields, expires_at)
      body = response.body
      if body.nil?
        text = "".b
      elsif body.is_a?(Protocol::HTTP::Body::Buffered)
        text = body.chunks.size == 1 ? body.chunks[0] : body.chunks.join
      elsif (length = body.length) && length <= MAX_CACHE_ITEM
        text = body.join || "".b
        response = Protocol::HTTP::Response[status, response.headers, Protocol::HTTP::Body::Buffered.new([text], text.bytesize)]
      else
        return response
      end
      variant = vary_names(fields)&.map { |name| [name, request.headers[name]&.to_s || ""].freeze }&.freeze
      stored = []
      fields.each { |name, value| stored << [name, value].freeze unless name == X_CACHE }
      size = text.bytesize + key.bytesize + ENTRY_OVERHEAD
      stored.each { |name, value| size += name.bytesize + value.to_s.bytesize }
      store.set(key, Entry.new(status, stored.freeze, text.frozen? ? text : text.dup.freeze, variant, expires_at, size))
      response
    end

    def vary_names(fields)
      vary = field(fields, VARY)
      return nil if vary.nil? || vary.empty?
      vary.split(",").map! { |n| n.strip.downcase }.sort!
    end

    # WriteCachedResponse: the stored response, or a 304 when the request names its ETag.
    def hit(entry, request)
      fields = entry.fields.dup
      status = entry.status
      body = entry.body
      if (etag = field(fields, ETAG)) && (inm = request.headers["if-none-match"]) &&
          inm.to_s.split(",").any? { |candidate| candidate.strip == etag }
        status = 304
        body = nil
      end
      fields << [X_CACHE, HIT]
      suppress_bodiless(status, fields)
      body = nil if body&.empty? || request.method == "HEAD"
      body &&= Protocol::HTTP::Body::Buffered.new([body], body.bytesize)
      Protocol::HTTP::Response[status, Protocol::HTTP::Headers.new(fields), body]
    end

    # Go's http.Server drops the headers a status can't carry.
    def suppress_bodiless(status, fields)
      if status == 304
        delete_field(fields, CONTENT_TYPE)
        delete_field(fields, CONTENT_LENGTH)
      elsif status == 204 || status < 200
        delete_field(fields, CONTENT_LENGTH)
      end
    end

    # ---- Rack::Deflater ----------------------------------------------------

    def deflate(request, response)
      digested = PageParts.take_digested # set by rails! for this response's body, if any
      status = response.status
      fields = response.headers.to_a
      if fields.any? { |name, _| name == NO_DEFLATE }
        delete_field(fields, NO_DEFLATE)
        return response
      end
      return response if status < 200 || status == 204 || status == 304
      return response if (cc = field(fields, CACHE_CONTROL)) && cc.match?(/\bno-transform\b/)
      return response if (ce = field(fields, CONTENT_ENCODING)) && !ce.match?(/\bidentity\b/)

      vary = field(fields, VARY)
      unless vary && (vary.include?("*") || vary.match?(/accept-encoding/i))
        if vary
          delete_field(fields, VARY)
          fields << [VARY, "#{vary},#{ACCEPT_ENCODING}"]
        else
          fields << [VARY, ACCEPT_ENCODING]
        end
      end
      return response unless accepts_gzip?(request.headers["accept-encoding"]&.to_s)

      delete_field(fields, CONTENT_LENGTH)
      fields << [CONTENT_ENCODING, GZIP]
      body = response.body
      if request.method == "HEAD"
        body = nil
      elsif body.nil?
        body = Protocol::HTTP::Body::Buffered.new([EMPTY_GZIP], EMPTY_GZIP.bytesize)
      elsif body.is_a?(Protocol::HTTP::Body::Buffered) || ((length = body.length) && length <= MAX_BUFFERED_GZIP)
        text = body.is_a?(Protocol::HTTP::Body::Buffered) && body.chunks.size == 1 ? body.chunks[0] : body.join
        gz = text.nil? || text.empty? ? EMPTY_GZIP : ((parts = PageParts.of(text)) && PageParts.gzip(text, parts)) || PageParts.gzip_digested(text, digested) || Zlib.gzip(text)
        body = Protocol::HTTP::Body::Buffered.new([gz], gz.bytesize)
      else
        body = GzipBody.new(body)
      end
      Protocol::HTTP::Response[status, response.headers, body]
    end

    # Rack::Deflater's select_best_encoding over %w[gzip identity]: gzip unless it (or `*`)
    # is absent or q=0, or identity is preferred by a strictly higher q.
    def accepts_gzip?(header)
      return false if header.nil? || header.empty?
      gzip = star = identity = nil
      header.split(",") do |part|
        coding, params = part.split(";", 2)
        coding = coding.strip
        q = 1.0
        if params && (i = params.index("q="))
          q = params[i + 2..].to_f
        end
        case coding
        when "gzip" then gzip ||= q
        when "*" then star ||= q
        when "identity" then identity ||= q
        end
      end
      q = gzip || star or return false
      q > 0 && (identity.nil? || q >= identity)
    end

    # A streamed body gzipped as it is read (for files over MAX_BUFFERED_GZIP).
    class GzipBody < Protocol::HTTP::Body::Readable
      def initialize(body)
        @body = body
        @zstream = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, Zlib::MAX_WBITS | 16)
      end

      def read
        return nil unless @zstream
        while (chunk = @body.read)
          out = @zstream.deflate(chunk)
          return out unless out.empty?
        end
        out = @zstream.finish
        close
        out
      end

      def close(error = nil)
        @zstream&.close
        @zstream = nil
        @body.close(error) if @body.respond_to?(:close)
        super
      end

      def length = nil
      def empty? = @zstream.nil?
    end

    # ---- Rails (ActionDispatch::Response, Rack::ETag, Rack::ConditionalGet) --------------

    # Finishes a controller response: default headers (unless `live`, ActionController::Live
    # responses skip them), Content-Type default, Cache-Control normalisation, the weak
    # SHA-256 ETag of Rack::ETag and the 304 of Rack::ConditionalGet. Mutates `fields`;
    # returns the (possibly 304) status and body.
    def rails!(request, status, fields, body, live: false)
      cc = etag = last_modified = type = nil
      fields.each do |name, value|
        case name
        when CACHE_CONTROL then cc = value
        when ETAG then etag = value
        when LAST_MODIFIED then last_modified = value
        when CONTENT_TYPE then type = value
        end
      end
      # merge_and_normalize_cache_control! (a Live response commits before it runs, so a
      # Live 304 leaves Rack::ETag to say `no-cache`)
      if cc.nil? && !live && (etag || last_modified)
        fields << [CACHE_CONTROL, cc = REVALIDATE]
      end
      DEFAULT_HEADERS.each { |pair| fields << pair } unless live
      if type.nil? && status >= 200 && status != 204 && status != 205 && status != 304
        fields << [CONTENT_TYPE, HTML_UTF8]
      end
      # Rack::ETag
      digested = false
      if !live && etag.nil? && last_modified.nil? && (status == 200 || status == 201) && body.is_a?(String) && !body.empty?
        # OpenSSL (SHA-NI) is ~7x faster than Digest::SHA256 on a 450KB page; one per Ractor
        # since OpenSSL::Digest.hexdigest is an unshareable define_method Proc.
        if (parts = PageParts.of(body))
          digest = PageParts.digest(body, parts)
        else
          digest = (Ractor[:campfire_sha256] ||= OpenSSL::Digest.new("SHA256")).reset.update(body).digest
          PageParts.digested(body, digest)
        end
        etag = +"W/\"" << digest.unpack1("H32") << "\""
        fields << [ETAG, etag]
        digested = true
      end
      fields << [CACHE_CONTROL, digested ? REVALIDATE : NO_CACHE] unless cc
      # Rack::ConditionalGet
      if status == 200 && (request.method == "GET" || request.method == "HEAD") && fresh?(request, etag, last_modified)
        delete_field(fields, CONTENT_TYPE)
        delete_field(fields, CONTENT_LENGTH)
        return [304, nil]
      end
      [status, body]
    end

    # request.fresh? with strict_freshness: If-None-Match naming the ETag (or `*`), else
    # If-Modified-Since no earlier than Last-Modified.
    def fresh?(request, etag, last_modified)
      headers = request.headers
      if (inm = headers["if-none-match"])
        return false unless etag
        inm.to_s.split(",").any? { |v| (v = v.strip) == etag || v == "*" }
      elsif last_modified && (ims = headers["if-modified-since"])
        since = (Time.httpdate(ims.to_s) rescue nil) or return false
        modified = (Time.httpdate(last_modified) rescue nil) or return false
        since >= modified
      else
        false
      end
    end

    # A response built outside a controller (Active Storage, health check) finished the
    # same way. Public exception pages pass through untouched.
    def finish_response(request, response, live: false)
      fields = response.headers.to_a
      return response if field(fields, CONTENT_TYPE) == PUBLIC_ERROR_TYPE
      body = response.body
      text = nil
      if body.is_a?(Protocol::HTTP::Body::Buffered)
        text = body.chunks.size == 1 ? body.chunks[0] : body.chunks.join
      end
      status, = rails!(request, response.status, fields, text, live: live)
      return response if status == response.status
      Protocol::HTTP::Response[status, response.headers, nil]
    end

    # The first value of a header field, or nil.
    def field(fields, name)
      fields.each { |n, v| return v if n == name }
      nil
    end

    def delete_field(fields, name)
      fields.reject! { |n, _| n == name }
    end
  end
end
