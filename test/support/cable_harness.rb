# frozen_string_literal: true

# Boots just enough of Campfire to serve /cable from an in-process Falcon
# server (main Ractor, Bus not started, so broadcasts deliver inline) against
# a private copy of the seed database.
require "fileutils"
require "tmpdir"
require_relative "../../lib/campfire"
require_relative "cable_client"
require_relative "../../lib/campfire/controller"
require_relative "../../lib/campfire/cable"
Dir[File.join(File.expand_path("../..", __dir__), "app/channels/**/*.rb")].sort.each { |f| require f }

module CableHarness
  ROOT = File.expand_path("../..", __dir__)
  SEED = File.join(ROOT, "tmp/seed/db/production.sqlite3")
  COOKIE_FILE = "/home/tobi/src/once/ref-html/cookie.txt"
  SECRET = "5335c3b1ad35b4ad170c3413bd651ef3b6ed64e257261871a6de3f978cf3868ee417a927040935fb30b0f7debdedb34a2a403e9f34b16cf594c917c2ecd4a995"
  WATERCOOLER = 486777696  # Rooms::Closed, David is a member
  HQ = 201306877
  DAVID = 127326141

  module_function

  def boot!
    return @port if @port
    dir = Dir.mktmpdir("cable-test")
    FileUtils.cp(SEED, File.join(dir, "db.sqlite3"))
    config = Campfire::Config.from_env(
      "SECRET_KEY_BASE" => SECRET, "CAMPFIRE_DATABASE_PATH" => File.join(dir, "db.sqlite3"),
      "CAMPFIRE_FILES_PATH" => dir, "PORT" => "0", "WEB_CONCURRENCY" => "1"
    )
    Campfire.const_set(:CONFIG, config) unless Campfire.const_defined?(:CONFIG)
    Campfire.const_set(:SECRETS, Campfire::RailsCompat::Secrets.new(SECRET)) unless Campfire.const_defined?(:SECRETS)
    app = Object.new
    def app.call(request) = Campfire::Cable.call(request)
    server = TCPServer.new("127.0.0.1", 0)
    @port = server.addr[1]
    ready = Thread::Queue.new
    @thread = Thread.new do
      Sync do |task|
        endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{@port}")
        bound = IO::Endpoint::BoundEndpoint.new(endpoint, [Socket.for_fd(server.fileno).tap { |s| s.autoclose = false }])
        Campfire::Cable.attach(task)
        ready << true
        Falcon::Server.new(app, bound, protocol: endpoint.protocol, scheme: "http").run.wait
      end
    end
    ready.pop
    @db_path = File.join(dir, "db.sqlite3")
    ensure_session!(db)
    @port
  end

  # The reference cookie names a session the Rails app created at login; make
  # sure our seed copy has it (for David).
  def ensure_session!(db)
    raw = cookie[/session_token=([^;]+)/, 1]
    token = Campfire.secrets.verify_cookie("session_token", Campfire::RailsCompat.unescape_cookie(raw))
    return unless token && db.query_single_splat("SELECT count(*) FROM sessions WHERE token = ?", token).zero?
    now = Campfire::Clock.now_db
    db.execute("INSERT INTO sessions (user_id, token, last_active_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", DAVID, token, now, now, now)
  end

  def port = @port
  def db = (@db ||= Campfire::DB.open(@db_path))
  def cookie = File.read(COOKIE_FILE).strip
  def client(**opts) = CableClient.new("127.0.0.1", boot!, cookie: cookie, **opts)

  # Run a block inside the server's Ractor/thread context (registry is Ractor-local,
  # so the main thread sees the same registry).
  def registry = Campfire::Cable::Registry.current

  def signed(name) = Campfire.secrets.signed_stream_name(name)
  def gid_param(type, id) = Campfire::RailsCompat::GID.build(type, id).to_param
end
