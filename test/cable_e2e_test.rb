# frozen_string_literal: true

# End to end: boots the real server (bin/campfire, WEB_CONCURRENCY=4) on a
# fresh seed copy in tmp/seed-cable, connects Action Cable clients with the
# reference session cookie until they sit on different worker Ractors (the
# upgrade names the worker when CAMPFIRE_CABLE_DEBUG=1), and checks that
# broadcasts made on one worker reach sockets on the others.
require "minitest/autorun"
require "fileutils"
require "net/http"
require_relative "../lib/campfire"
require_relative "support/cable_client"

class CableE2ETest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PORT = Integer(ENV.fetch("CABLE_E2E_PORT", "3291"))
  SECRET = "5335c3b1ad35b4ad170c3413bd651ef3b6ed64e257261871a6de3f978cf3868ee417a927040935fb30b0f7debdedb34a2a403e9f34b16cf594c917c2ecd4a995"
  COOKIE = File.read("/home/tobi/src/once/ref-html/cookie.txt").strip
  ROOM = 486777696 # All Talk (Rooms::Closed): David, Jason, Bender Bot
  DAVID = 127326141
  SECRETS = Campfire::RailsCompat::Secrets.new(SECRET)

  def self.server
    @server ||= begin
      seed = File.join(ROOT, "tmp/seed-cable")
      FileUtils.rm_rf(seed)
      FileUtils.cp_r(File.join(ROOT, "tmp/seed"), seed)
      db_path = File.join(seed, "db/production.sqlite3")
      ensure_session!(db_path)
      log = File.join(ROOT, "tmp/cable-e2e.log")
      env = { "CAMPFIRE_DATABASE_PATH" => db_path, "CAMPFIRE_FILES_PATH" => File.join(seed, "storage"),
              "PORT" => PORT.to_s, "WEB_CONCURRENCY" => "4", "CAMPFIRE_CABLE_DEBUG" => "1" }
      pid = Process.spawn(env, "zsh", "-c", "source bin/dev-env && exec mise exec -- bundle exec ruby bin/campfire",
        chdir: ROOT, pgroup: true, out: log, err: log)
      Minitest.after_run { Process.kill("-TERM", pid) rescue nil; Process.wait(pid) rescue nil }
      deadline = Time.now + 60
      until (begin; TCPSocket.new("127.0.0.1", PORT).close; true; rescue SystemCallError; false; end)
        raise "server did not start; see #{log}" if Time.now > deadline
        sleep 0.2
      end
      pid
    end
  end

  def self.ensure_session!(db_path)
    raw = COOKIE[/session_token=([^;]+)/, 1]
    token = SECRETS.verify_cookie("session_token", Campfire::RailsCompat.unescape_cookie(raw)) or raise "cookie does not verify"
    db = Extralite::Database.new(db_path)
    if db.query_single_splat("SELECT count(*) FROM sessions WHERE token = ?", token).zero?
      now = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
      db.execute("INSERT INTO sessions (user_id, token, last_active_at, user_agent, ip_address, created_at, updated_at) VALUES (?, ?, ?, 'e2e', '127.0.0.1', ?, ?)",
        DAVID, token, now, now, now)
    end
    db.close
  end

  def setup = self.class.server

  def connect
    c = CableClient.new("127.0.0.1", PORT, cookie: COOKIE)
    assert_equal 101, c.status
    assert_equal "welcome", c.read_message["type"]
    c
  end

  # One client per worker Ractor (at least two workers).
  def clients_on_workers
    by_worker = {}
    spare = []
    60.times do
      c = connect
      w = c.headers["x-campfire-worker"] or flunk "no x-campfire-worker header (CAMPFIRE_CABLE_DEBUG)"
      by_worker.key?(w) ? spare << c : by_worker[w] = c
      break if by_worker.size == 4
    end
    spare.each(&:close)
    assert_operator by_worker.size, :>=, 2, "all sockets landed on one worker"
    by_worker
  end

  def confirm(c, identifier)
    c.subscribe(identifier)
    msg = c.read_message
    assert_equal "confirm_subscription", msg["type"], msg.inspect
    assert_equal identifier, msg["identifier"]
  end

  def gid_param = Campfire::RailsCompat::GID.build("Rooms::Closed", ROOM).to_param

  def test_broadcasts_cross_worker_ractors
    clients = clients_on_workers
    messages_id = JSON.generate(channel: "RoomMessagesChannel", signed_stream_name: SECRETS.signed_stream_name(gid_param, "messages"))
    reads_id = JSON.generate(channel: "ReadRoomsChannel")
    clients.each_value { |c| confirm(c, messages_id); confirm(c, reads_id) }

    # 1. Presence on one worker -> user_reads broadcast (Membership#present)
    #    -> David's ReadRoomsChannel sockets on every worker.
    origin_worker, origin = clients.first
    presence_id = JSON.generate(channel: "PresenceChannel", room_id: ROOM)
    confirm(origin, presence_id)
    clients.each do |w, c|
      msg = c.read_message(5)
      assert_equal({ "identifier" => reads_id, "message" => { "room_id" => ROOM } }, msg, "worker #{w} (origin #{origin_worker})")
    end

    # 2. A message posted over HTTP (MessagesController#create on whichever
    #    worker accepts it): the turbo-stream append reaches every worker.
    marker = "e2e cross-ractor #{SecureRandom.hex(4)}"
    res = Net::HTTP.start("127.0.0.1", PORT) do |http|
      page = http.get("/rooms/#{ROOM}", "Cookie" => COOKIE)
      csrf = page.body[/name="csrf-token" content="([^"]+)"/, 1] or flunk "no csrf token"
      form = URI.encode_www_form("message[body]" => marker, "message[client_message_id]" => SecureRandom.uuid)
      http.post("/rooms/#{ROOM}/messages", form, "Cookie" => COOKIE, "X-CSRF-Token" => csrf,
        "Accept" => "text/vnd.turbo-stream.html, text/html", "Content-Type" => "application/x-www-form-urlencoded")
    end
    assert_equal "200", res.code
    clients.each do |w, c|
      msg = nil
      3.times { (msg = c.read_message(5)) && msg["identifier"] == messages_id && break }
      assert msg, "worker #{w} got nothing"
      assert_equal messages_id, msg["identifier"]
      assert_includes msg["message"], %(action="append")
      assert_includes msg["message"], marker
    end
    puts "\n  cross-worker delivery verified on workers #{clients.keys.sort.join(",")} (presence origin #{origin_worker})"
  ensure
    clients&.each_value(&:close)
  end
end
