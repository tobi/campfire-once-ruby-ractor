# frozen_string_literal: true

# Boots the whole app in-process (no server, no Ractors) against a private
# copy of the seed database and drives it with Protocol::HTTP requests.
# Broadcasts, Bus publishes and Jobs.later calls are captured, not delivered.
require "fileutils"
require "tmpdir"
require "protocol/http"
require_relative "../../lib/campfire"

# Extralite 2.x (SQLite 3.53.4) segfaults while finalizing a database that
# wrote to an FTS5 table (message creation indexes the message), so leave the
# process with exit! once Minitest has reported, keeping its exit status.
if defined?(Minitest)
  module AppHarnessExit
    def run(args = [])
      ok = super
      $stdout.flush
      $stderr.flush
      exit!(ok ? 0 : 1)
    end
  end
  Minitest.singleton_class.prepend(AppHarnessExit)
end

module AppHarness
  ROOT = File.expand_path("../..", __dir__)
  SEED = ENV["APP_HARNESS_SEED"] || File.join(ROOT, "tmp/seed/db/production.sqlite3")
  COOKIE_FILE = "/home/tobi/src/once/ref-html/cookie.txt"
  SECRET = "5335c3b1ad35b4ad170c3413bd651ef3b6ed64e257261871a6de3f978cf3868ee417a927040935fb30b0f7debdedb34a2a403e9f34b16cf594c917c2ecd4a995"
  HOST = "127.0.0.1:3100"
  DAVID = 127326141

  Response = Struct.new(:status, :headers, :body)

  module_function

  def boot!
    return if @booted
    dir = Dir.mktmpdir("app-test")
    FileUtils.cp(SEED, File.join(dir, "db.sqlite3"))
    FileUtils.mkdir_p(File.join(dir, "files"))
    config = Campfire::Config.from_env(
      "SECRET_KEY_BASE" => SECRET, "CAMPFIRE_DATABASE_PATH" => File.join(dir, "db.sqlite3"),
      "CAMPFIRE_FILES_PATH" => File.join(dir, "files"), "PORT" => "0", "WEB_CONCURRENCY" => "1",
      "VAPID_PUBLIC_KEY" => ENV["VAPID_PUBLIC_KEY"], "VAPID_PRIVATE_KEY" => ENV["VAPID_PRIVATE_KEY"]
    )
    Campfire.boot!(config)
    @app = Campfire::App.new
    capture!
    ensure_session!
    @booted = true
  end

  # Records Cable.broadcast / Bus.publish / Jobs.later instead of delivering.
  def capture!
    log = (@captured = [])
    Campfire::Cable.define_singleton_method(:broadcast) { |stream, payload| log << [:broadcast, stream, payload]; nil }
    Campfire::Bus.define_singleton_method(:publish) { |msg| log << [:bus, *msg]; nil }
    Campfire::Jobs.define_singleton_method(:later) { |kind, *args| log << [:job, kind, *args]; nil }
    Campfire::Jobs.define_singleton_method(:call) { |kind, *args| log << [:job_call, kind, *args]; nil }
  end

  def captured = @captured
  def db = Campfire::DB.connection
  def cookie_header = (@cookie ||= File.read(COOKIE_FILE).strip)

  def ensure_session!
    raw = cookie_header[/session_token=([^;]+)/, 1]
    token = Campfire.secrets.verify_cookie("session_token", Campfire::RailsCompat.unescape_cookie(raw))
    return unless token && db.query_single_splat("SELECT count(*) FROM sessions WHERE token = ?", token).zero?
    now = Campfire::Clock.now_db
    db.execute("INSERT INTO sessions (user_id, token, last_active_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", DAVID, token, now, now, now)
  end

  # A browser-ish client: keeps cookies, and marks its writes same-origin by Sec-Fetch-Site, as
  # the app's own pages make them.
  class Client
    SAME_ORIGIN = { "sec-fetch-site" => "same-origin" }.freeze

    def initialize
      @cookies = {}
      AppHarness.cookie_header.split(/;\s*/).each { |kv| k, v = kv.split("=", 2); @cookies[k] = v if v }
    end

    attr_reader :cookies

    def get(path, headers = {}) = request("GET", path, nil, headers)

    def form(method, path, params, headers = {})
      body = URI.encode_www_form(params)
      request(method, path, body, { "content-type" => "application/x-www-form-urlencoded" }.merge(SAME_ORIGIN, headers))
    end

    def multipart(path, fields, file_field, filename, type, data)
      boundary = "----harness#{rand(1 << 32)}"
      body = +"".b
      fields.each do |k, v|
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{k}\"\r\n\r\n#{v}\r\n".b
      end
      body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{file_field}\"; filename=\"#{filename}\"\r\nContent-Type: #{type}\r\n\r\n".b
      body << data.b << "\r\n--#{boundary}--\r\n".b
      request("POST", path, body, { "content-type" => "multipart/form-data; boundary=#{boundary}" }.merge(SAME_ORIGIN))
    end

    def request(method, path, body, headers)
      h = Protocol::HTTP::Headers.new
      h.add("user-agent", ENV["APP_HARNESS_UA"] || "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
      h.add("accept", "text/vnd.turbo-stream.html, text/html, application/xhtml+xml")
      h.add("cookie", @cookies.map { |k, v| "#{k}=#{v}" }.join("; "))
      headers.each { |k, v| h.add(k, v) if v }
      req = Protocol::HTTP::Request.new("http", HOST, method, path, "HTTP/1.1", h, body && Protocol::HTTP::Body::Buffered.wrap(body))
      res = AppHarness.app.call(req)
      out = res.body ? res.body.join.to_s : +""
      rh = {}
      res.headers.each do |k, v|
        if k == "set-cookie"
          name, val = v.split(";", 2).first.split("=", 2)
          @cookies[name] = val
        end
        rh[k] = v.to_s
      end
      Response.new(res.status, rh, out.force_encoding(Encoding::UTF_8))
    end
  end

  def app = @app
end
