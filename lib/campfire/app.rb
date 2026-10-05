# frozen_string_literal: true

module Campfire
  # The Falcon application: a Protocol::HTTP callable (no Rack env hash).
  class App
    HEALTH = %(<!DOCTYPE html><html><body style="background-color: green"></body></html>)
    FORM = "application/x-www-form-urlencoded"
    MULTIPART = "multipart/form-data"
    METHOD_PART = 'name="_method"'
    STORAGE_PREFIX = "/rails/active_storage/"
    CABLE = "/cable"

    def initialize
      @dispatch = method(:dispatch)
    end

    # Thruster and Rack::Deflater (Front) around everything but the WebSocket endpoint.
    def call(request)
      full = request.path
      if full.start_with?(CABLE) && (full.bytesize == 6 || full.getbyte(6) == 63)
        response = Cable.call(request)
        return response unless response.status == 404
        # Action Cable's own 404 (not a WebSocket request), under Rack::ETag and Thruster.
        response.headers.to_a << [Front::CACHE_CONTROL, Front::NO_CACHE]
        return Front.call(->(_) { response }, request)
      end
      Front.call(@dispatch, request)
    end

    def dispatch(request)
      full = request.path
      if (q = full.index("?"))
        path = full[0, q]
        query = full[q + 1..]
      else
        path = full
      end

      verb = request.method
      # ActionDispatch::Static: GET/HEAD of a public file, before routing.
      if (verb == "GET" || verb == "HEAD") && (file = Assets.file(path))
        return static(file, request)
      end
      return health(request) if path == "/up"
      if path.start_with?(STORAGE_PREFIX)
        # ActiveStorage controllers; the proxy ones stream (ActionController::Live).
        return Front.finish_response(request, Storage.call(request, path, query), live: path.include?("/proxy/"))
      end

      body = nil
      if verb == "POST" && request.headers["content-type"]&.to_s&.start_with?(FORM)
        body = (request.body&.join || +"").force_encoding(Encoding::UTF_8)
        if (i = body.index("_method="))
          m = body[i + 8, 6].to_s[/\A[a-z]+/i]
          verb = m.upcase if m && %w[PATCH PUT DELETE].include?(m.upcase)
        end
      elsif verb == "POST" && request.headers["content-type"]&.to_s&.start_with?(MULTIPART)
        # Rails forms with file inputs carry _method as a multipart part.
        body = (request.body&.join || +"").force_encoding(Encoding::BINARY)
        if (i = body.byteindex(METHOD_PART)) && (j = body.byteindex("\r\n\r\n", i))
          m = body.byteslice(j + 4, 6).to_s[/\A[a-z]+/i]
          verb = m.upcase if m && %w[PATCH PUT DELETE].include?(m.upcase)
        end
        body.force_encoding(Encoding::UTF_8)
      end

      route, params, format = ROUTES.recognize(verb, path)
      return public_error(404, request) unless route
      params["format"] = format if format
      controller = route.controller.new(request, path, query, params)
      controller.body_string = body if body
      controller.format = format || params["format"]
      if verb == "GET" || verb == "HEAD"
        DB.connection.read { controller.dispatch(route.action) } # see DB::Connection
      else
        controller.dispatch(route.action)
      end
    rescue => e
      Log.error("#{request.method} #{request.path}", e)
      public_error(500, request)
    end

    private

    # Rack::Files: Last-Modified (304 when If-Modified-Since repeats it exactly), the public
    # file server's Cache-Control, Content-Length; no ETag.
    def static(file, request)
      if request.headers["if-modified-since"]&.to_s == file.last_modified
        return Responses.build(304, [], nil)
      end
      headers = [["last-modified", file.last_modified], ["content-type", file.type],
        ["cache-control", Assets::CACHE_CONTROL]]
      head = request.method == "HEAD"
      status = 200
      body = file.body
      if (range = request.headers["range"]&.to_s) && !range.empty?
        status, body = static_range(range, body, headers)
      end
      # The HTTP/1 writer derives Content-Length from the body; only HEAD states it.
      headers << ["content-length", body.bytesize.to_s] if head
      headers << [Front::NO_DEFLATE, "1"] if body.empty?
      Responses.build(status, headers, head ? nil : body)
    end

    # Rack::Utils.byte_ranges: one satisfiable `bytes=a-b` / `a-` / `-n` range gives 206 with
    # Content-Range; none satisfiable gives 416. Malformed or multiple ranges serve the whole file.
    def static_range(spec, body, headers)
      size = body.bytesize
      m = spec.match(/\Abytes=\s*(\d*)\s*-\s*(\d*)\s*\z/) or return [200, body]
      first, last = m[1], m[2]
      return [200, body] if first.empty? && last.empty?
      if first.empty?
        first = size - last.to_i
        first = 0 if first.negative?
        last = size - 1
      else
        first = first.to_i
        last = last.empty? ? size - 1 : [last.to_i, size - 1].min
      end
      if first > last || first >= size
        headers << ["content-range", "bytes */#{size}"]
        return [416, "Byte range unsatisfiable\n"] # Rack::Files' body
      end
      headers << ["content-range", "bytes #{first}-#{last}/#{size}"]
      [206, body.byteslice(first, last - first + 1)]
    end

    # Rails::HealthController#show
    def health(request)
      fields = [["content-type", Front::HTML_UTF8]]
      fields << ["vary", Front::ACCEPT] if Front.vary_accept?(request, nil)
      status, body = Front.rails!(request, 200, fields, HEALTH)
      Responses.build(status, fields, body)
    end


    # ActionDispatch::PublicExceptions: public/<status>.html with its own Content-Length.
    def public_error(status, request)
      body = request&.method == "HEAD" ? nil : (Assets.file("/#{status}.html")&.body || "")
      headers = [["content-type", Front::PUBLIC_ERROR_TYPE]]
      headers << [Front::NO_DEFLATE, "1"] if body.nil? || body.empty?
      Responses.build(status, headers, body)
    end
  end
end
