# frozen_string_literal: true

require "securerandom"

module Campfire
  # One instance per request. Holds request state, lazily decodes params,
  # cookies and the Rails session, and renders views into a single buffer.
  # Views and helpers are mixed in (see app/helpers, compiled templates).
  class Controller
    include Responses

    HTML_CAPACITY = 64 * 1024
    SESSION_COOKIE = "_campfire_session"
    TOKEN_COOKIE = "session_token"
    ACTIVITY_REFRESH = 3600

    attr_reader :request, :path, :db, :route
    attr_accessor :status
    attr_writer :body_string

    def initialize(request, path, query, route = nil)
      @request = request
      @path = path
      @query_string = query
      @route = route
      @db = DB.connection
      @status = 200
      @headers = []
      @flash_next = nil
    end

    # ---- request ------------------------------------------------------

    def method = @request.method
    def get? = @request.method == "GET" || @request.method == "HEAD"
    def header(name) = @request.headers[name]

    # Header values arrive as ASCII-8BIT; Extralite binds binary strings as
    # BLOBs, which never compare equal to TEXT columns (bans.ip_address) and
    # would be stored as BLOBs (sessions.user_agent). Retag (no copy) as UTF-8.
    def text_header(name)
      s = header(name)&.to_s or return
      s = s.dup if s.frozen?
      s.force_encoding(Encoding::UTF_8)
      s.valid_encoding? ? s : s.scrub
    end

    def user_agent = (@user_agent ||= text_header("user-agent") || "")
    def host_with_port = (@host ||= @request.authority || header("host") || "localhost")
    def scheme = (@scheme ||= header("x-forwarded-proto")&.to_s || @request.scheme || "http")
    def base_url = (@base_url ||= "#{scheme}://#{host_with_port}")
    def url = "#{base_url}#{@request.path}"
    def remote_ip
      @remote_ip ||= (text_header("x-forwarded-for")&.split(",")&.first&.strip ||
        @request.remote_address&.ip_address || "127.0.0.1")
    rescue
      "127.0.0.1"
    end

    def xhr? = header("x-requested-with")&.to_s == "XMLHttpRequest"
    def turbo_frame = header("turbo-frame")&.to_s
    def accepts_turbo_stream? = header("accept")&.to_s&.include?("text/vnd.turbo-stream.html")
    def wants_json? = @format == "json" || header("accept")&.to_s&.start_with?("application/json")
    def format = @format
    def format=(f)
      @format = f
    end

    def query
      @query ||= Params.decode(@query_string)
    end

    def params
      @params ||= begin
        h = Params.decode(@query_string)
        @route&.each { |k, v| h[k] = v }
        merge_body_params(h)
        h
      end
    end

    def param(key) = params[key]

    def body_string
      @body_string ||= begin
        b = @request.body
        s = b ? b.join : +""
        s.force_encoding(Encoding::UTF_8)
      end
    end

    def content_type = header("content-type")&.to_s || ""

    def merge_body_params(h)
      return if get?
      ct = content_type
      if ct.start_with?("application/x-www-form-urlencoded")
        Params.decode(body_string, h)
      elsif ct.start_with?("multipart/form-data")
        Multipart.parse(body_string, ct, h)
      elsif ct.start_with?("application/json")
        json = JSON.parse(body_string) rescue nil
        h.merge!(json) if json.is_a?(Hash)
      end
    end

    # ---- cookies ------------------------------------------------------

    def cookies
      @cookies ||= begin
        h = {}
        if (raw = header("cookie"))
          raw.to_s.split(/; */).each do |pair|
            k, v = pair.split("=", 2)
            h[k] = RailsCompat.unescape_cookie(v) if k && v && !h.key?(k)
          end
        end
        h
      end
    end

    def set_cookie(name, value, path: "/", expires: nil, httponly: false, same_site: nil)
      c = +"#{name}=#{RailsCompat.escape_cookie(value.to_s)}; path=#{path}"
      c << "; expires=#{expires.httpdate}" if expires
      c << "; httponly" if httponly
      c << "; samesite=#{same_site}" if same_site
      put_cookie_header(name, c)
    end

    def delete_cookie(name, path: "/")
      put_cookie_header(name, "#{name}=; path=#{path}; max-age=0; expires=Thu, 01 Jan 1970 00:00:00 GMT")
    end

    # Rails' cookie jar emits one Set-Cookie per name: the last write wins.
    def put_cookie_header(name, cookie)
      n = name.bytesize
      @headers.each do |h|
        next unless h[0] == "set-cookie" && h[1].getbyte(n) == 61 && h[1].start_with?(name)
        h[1] = cookie
        return
      end
      @headers << ["set-cookie", cookie]
    end

    # ---- Rails session (encrypted cookie) -----------------------------

    def session
      @session ||= begin
        raw = cookies[SESSION_COOKIE]
        (raw && Cache.session(raw)) || {}
      end
    end

    # A write of the value the session already holds changes nothing, so no cookie goes out.
    def session_write(key, value)
      return if session[key] == value && @session.key?(key)
      @session = @session.dup if @session.frozen?
      @session[key] = value
      @session_dirty = true
    end

    def session_delete(key)
      return nil unless session.key?(key)
      @session = @session.dup if @session.frozen?
      @session_dirty = true
      @session.delete(key)
    end

    def reset_session
      @session = {}
      @session_dirty = true
    end

    # Unlike Rails, the session cookie is written only when the session changed, and deleted once
    # it holds nothing but its id (and the _csrf_token Rails sessions carry, which no longer counts).
    def commit_session
      return unless @session_dirty
      if @session.each_key.all? { |k| k == "session_id" || k == "_csrf_token" }
        delete_cookie(SESSION_COOKIE) if cookies[SESSION_COOKIE]
        return
      end
      @session = @session.dup if @session.frozen?
      @session.delete("_csrf_token")
      # Rails' CookieStore discards a cookie session that has no session_id, so always write one.
      @session["session_id"] ||= SecureRandom.hex(16)
      expires = Campfire.secrets.permanent_expiry
      value = Campfire.secrets.encrypt_cookie(SESSION_COOKIE, @session, expires: expires)
      set_cookie(SESSION_COOKIE, value, expires: expires, httponly: true, same_site: "lax")
    end

    # ---- flash --------------------------------------------------------

    def flash
      @flash ||= begin
        f = session["flash"]
        if f
          session_delete("flash")
          (f["flashes"] || {})
        else
          {}
        end
      end
    end

    def flash_next(key, value)
      (@flash_next ||= {})[key] = value
    end

    def commit_flash
      if @flash_next
        session_write("flash", { "discard" => [], "flashes" => @flash_next })
      end
    end

    # ---- forgery protection -------------------------------------------

    # verify_authenticity_token by Sec-Fetch-Site rather than tokens (RailsCompat::CSRF). A write
    # without the header passes only when neither the app (force_ssl) nor the request uses SSL.
    def verified_request?
      return true if get?
      ssl = Campfire.config.force_ssl || scheme == "https"
      RailsCompat::CSRF.valid_request?(header("origin")&.to_s, base_url, header("sec-fetch-site")&.to_s, ssl)
    end

    # ---- authentication -----------------------------------------------

    def current_user = @current_user
    def current_session = @current_session
    def signed_in? = !@current_user.nil?
    def authenticated_by_bot? = @authenticated_by == :bot_key

    def account
      @account ||= Account.first(@db)
    end

    def find_session_by_cookie
      raw = cookies[TOKEN_COOKIE] or return nil
      token = Cache.session_token(raw) or return nil
      Session.find_by_token(@db, token)
    end

    def restore_authentication
      if (s = find_session_by_cookie)
        resume_session(s)
        true
      end
    end

    # The session's activity is refreshed at most hourly, and the session_token cookie is re-signed
    # on the same schedule rather than on every request as Rails does: its 20-year expiry keeps
    # rolling without a cookie on every response.
    def resume_session(s)
      refresh = Clock.to_time(s.last_active_at) < Time.now - ACTIVITY_REFRESH
      s.resume!(@db, user_agent, remote_ip) if refresh
      authenticated_as(s, cookie: refresh)
    end

    def authenticated_as(s, cookie: true)
      @current_session = s
      @current_user = User.find(@db, s.user_id)
      @authenticated_by = :session
      set_cookie(TOKEN_COOKIE, Cache.signed_session_token(s.token), expires: Campfire.secrets.permanent_expiry, httponly: true, same_site: "lax") if cookie
    end

    def start_new_session_for(user)
      s = Session.start!(@db, user.id, user_agent, remote_ip)
      authenticated_as(s)
    end

    def bot_authentication
      # Route params are slices of the (ASCII-8BIT) request path; a binary string
      # binds as a BLOB, which never equals the TEXT bot_token. Retag as UTF-8.
      key = params["bot_key"]
      key = key.dup.force_encoding(Encoding::UTF_8) if key && key.encoding != Encoding::UTF_8
      if key && !key.empty? && (bot = User.authenticate_bot(@db, key.strip))
        @current_user = bot
        @authenticated_by = :bot_key
        true
      end
    end

    def require_authentication
      return true if restore_authentication || bot_authentication
      session_write("return_to_after_authenticating", url)
      redirect_to("#{base_url}/session/new")
      false
    end

    def post_authenticating_url
      session_delete("return_to_after_authenticating") || "#{base_url}/"
    end

    def terminate_current_session
      @current_session&.destroy!(@db)
      reset_session
      delete_cookie(TOKEN_COOKIE)
      Cable.disconnect_user(@current_user.id, reconnect: true) if @current_user
    end

    # ---- rendering ----------------------------------------------------

    def buffer
      @b ||= String.new(capacity: HTML_CAPACITY, encoding: Encoding::UTF_8)
    end

    def html(status = 200)
      @b = String.new(capacity: HTML_CAPACITY, encoding: Encoding::UTF_8)
      yield
      finish_rendered(status, TEXT_HTML, @b)
    end

    def turbo_stream(status = 200)
      @b = String.new(capacity: 8192, encoding: Encoding::UTF_8)
      yield
      finish_rendered(status, TURBO_STREAM, @b)
    end

    def json(obj, status = 200)
      finish_rendered(status, JSON_TYPE, obj.is_a?(String) ? obj : JSON.generate(obj))
    end

    def text(str, status = 200, type = "text/plain; charset=utf-8")
      finish_rendered(status, type, str)
    end

    # `head status`: no body; Content-Type is the request format's (text/html by default)
    # unless the status carries no content.
    def head(status)
      finish(status, status < 200 || status == 204 || status == 205 || status == 304 ? nil : head_content_type, nil)
    end

    # `head status` halting a before_action: plain text/html, whatever the request format
    # (matches the reference; ref-rust's concerns::head).
    def filter_head(status)
      finish(status, "text/html", nil)
      throw :halt
    end

    def redirect_to(location, status: 302, notice: nil, alert: nil)
      flash_next("notice", notice) if notice
      flash_next("alert", alert) if alert
      location = "#{base_url}#{location}" if location.start_with?("/")
      @headers << ["location", location]
      finish(status, TEXT_HTML, nil)
    end

    def add_header(name, value)
      @headers << [name, value]
    end

    # ActionController::Live responses (ActiveStorage::Streaming: avatars, logos) get no
    # default headers and no Rack::ETag digest.
    def live_response? = false

    # stylesheet_link_tag (the layout's head) sends the preload `Link` header.
    def preload_links!
      @preload_links = true
    end

    HEAD_TYPES = { "json" => "application/json", "turbo_stream" => "text/vnd.turbo-stream.html", "html" => "text/html" }.freeze

    # Mime[formats.first]: the :format param, else the first type of a non-browser Accept.
    def head_content_type
      return HEAD_TYPES.fetch(@format, "text/html") if @format
      accept = header("accept")&.to_s
      if accept && !accept.match?(Front::BROWSER_LIKE_ACCEPTS)
        first = accept[/\A[^,;]*/].strip
        return first unless first.empty? || first == "*/*"
      end
      "text/html"
    end

    # `render`: like finish, plus the Vary: Accept that _set_vary_header adds.
    def finish_rendered(status, type, body)
      @render = true
      finish(status, type, body)
    end

    def finish(status, type, body)
      return public_error(status, body) if type == Front::PUBLIC_ERROR_TYPE
      commit_flash
      commit_session
      h = @headers
      h << ["vary", Front::ACCEPT] if @render && Front.vary_accept?(@request, @format) && !Front.field(h, "vary")
      if @preload_links
        if (i = h.index { |n, _| n == "link" })
          h[i] = ["link", "#{h[i][1]},#{Assets::PRELOAD_LINK}"]
        else
          h << ["link", Assets::PRELOAD_LINK]
        end
      end
      h << ["content-type", type] if type
      h << ["x-version", Campfire.config.app_version]
      h << ["x-rev", Campfire.config.git_revision]
      status, body = Front.rails!(@request, status, h, body, live: live_response?)
      @response = Responses.build(status, h, body)
    end

    # What ShowExceptions renders for an exception (ActionDispatch::PublicExceptions): the
    # page alone, without the cookies or headers the action had set.
    def public_error(status, body)
      body = nil if @request.method == "HEAD"
      @headers = [["content-type", Front::PUBLIC_ERROR_TYPE]]
      @headers << [Front::NO_DEFLATE, "1"] if body.nil? || body.empty?
      @response = Responses.build(status, @headers, body)
    end

    def response = @response
  end
end
