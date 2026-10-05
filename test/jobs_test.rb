# frozen_string_literal: true

# :push_message, :push_test and :webhook job handlers against a private copy of
# the seed database and local fake push/webhook endpoints.
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/campfire"
%w[storage cable multipart rich_text web_push].each { |f| require_relative "../lib/campfire/#{f}" }
require_relative "../app/helpers/users/avatars_helper"
Dir[File.expand_path("../app/models/**/*.rb", __dir__)].sort.each { |f| require f }
Dir[File.expand_path("../app/jobs/**/*.rb", __dir__)].sort.each { |f| require f }
require_relative "support/fake_http"
Minitest::Assertions.diff = nil # forking diff(1) after async use crashes the child
# Extralite 3.1.3 segfaults closing any connection that wrote to an FTS5 table
# (even :memory:), so the message search index is skipped here.
Campfire::Message.singleton_class.class_eval("def index!(_db, _message) = nil")

module JobsHarness
  ROOT = File.expand_path("..", __dir__)
  SECRET = "5335c3b1ad35b4ad170c3413bd651ef3b6ed64e257261871a6de3f978cf3868ee417a927040935fb30b0f7debdedb34a2a403e9f34b16cf594c917c2ecd4a995"
  DIR = Dir.mktmpdir("jobs-test")
  FileUtils.cp(File.join(ROOT, "tmp/seed/db/production.sqlite3"), File.join(DIR, "db.sqlite3"))
  FileUtils.mkdir_p(File.join(DIR, "files"))
  Campfire.const_set(:CONFIG, Campfire::Config.from_env(
    "SECRET_KEY_BASE" => SECRET, "CAMPFIRE_DATABASE_PATH" => File.join(DIR, "db.sqlite3"),
    "CAMPFIRE_FILES_PATH" => File.join(DIR, "files"), "PORT" => "0",
    "VAPID_PUBLIC_KEY" => "BEYXTBB5_jNhNzXDmx5KEU55Vbbd-u--Lk9rM5OFQvUkPIBwZJ9QzAq0zdEzFw6yTV8cTriz_qYBVicY02_VxTQ=",
    "VAPID_PRIVATE_KEY" => "qfXLHghuG1rSHZUVo9SscNRI-0EIHRbIrfeGCqbAwak="
  ))
  Campfire.const_set(:SECRETS, Campfire::RailsCompat::Secrets.new(SECRET))
  Campfire::DB.prepare!(Campfire.config.database_path) if Campfire::DB.respond_to?(:prepare!)
end

class JobsTest < Minitest::Test
  W = Campfire::WebPush
  DB = Campfire::DB
  DESIGNERS = 654632876 # Rooms::Closed: David mentions, Kevin mentions (connected? no), JZ/Jason everything
  KEVIN_BENDER = 340026324 # Rooms::Direct
  DAVID, KEVIN, JASON, JZ, BENDER = 127326141, 712064548, 149087659, 773523953, 394959859

  def db = DB.connection

  # Tests share one database copy: restore what push tests mutate.
  SUBS = DB.connection.query_array("SELECT * FROM push_subscriptions")
  SUB_COLS = DB.connection.query_array("SELECT name FROM pragma_table_info('push_subscriptions')").flatten
  CONNECTED = DB.connection.query_array("SELECT id, connected_at FROM memberships")

  def setup
    db.transaction do
      db.execute("DELETE FROM push_subscriptions")
      SUBS.each { |row| db.execute("INSERT INTO push_subscriptions (#{SUB_COLS.join(", ")}) VALUES (#{(["?"] * row.size).join(", ")})", *row) }
      CONNECTED.each { |id, at| db.execute("UPDATE memberships SET connected_at = ? WHERE id = ?", at, id) }
    end
    @receiver = OpenSSL::PKey::EC.generate("prime256v1")
    @auth = OpenSSL::Random.random_bytes(16)
    @broadcasts = []
    sink = @broadcasts
    Campfire::Cable.singleton_class.send(:define_method, :local_broadcast_json) { |stream, json| sink << [stream, json] }
    @resolved = "127.0.0.1"
    resolved = -> { @resolved }
    W.singleton_class.send(:define_method, :resolve_endpoint_ip) { |_endpoint| resolved.call }
  end

  def mention(user_id, name)
    sgid = Campfire.secrets.attachable_sgid("User", user_id)
    %(<div>hey <action-text-attachment sgid="#{sgid}" content-type="application/vnd.campfire.mention" caption="#{name}"></action-text-attachment> look</div>)
  end

  def point_subscriptions_at(server, status_for = {})
    db.query_array("SELECT id FROM push_subscriptions").each do |(id)|
      db.execute("UPDATE push_subscriptions SET endpoint = ?, p256dh_key = ?, auth_key = ? WHERE id = ?",
        "http://127.0.0.1:#{server.port}/push/#{id}", W.b64(W.raw_public(@receiver)), W.b64(@auth), id)
    end
  end

  def open_push(req) = JSON.parse(W.decrypt(req.body, @receiver, @auth).force_encoding("UTF-8"))

  def test_push_message_targets_disconnected_everything_and_mentioned_users
    room = Campfire::Room.find(db, DESIGNERS)
    gone = db.query_single_splat("SELECT id FROM push_subscriptions WHERE user_id = ?", JZ)
    server = FakeHTTP.new { |req| req.path == "/push/#{gone}" ? [410, {}, ""] : [201, {}, ""] }
    point_subscriptions_at(server)
    david = Campfire::User.new(*db.query_single_array("SELECT #{Campfire::User::COLS} FROM users WHERE id = ?", DAVID))
    message = Campfire::Message.create!(db, room, david, body: mention(KEVIN, "Kevin"))
    Campfire::Delivery.receive(room, message) # Jobs.later(:push_message) (inline); the insert marked unread

    paths = server.requests.map(&:path).sort
    expected = db.query_array("SELECT id, user_id FROM push_subscriptions").to_h # after deletion
    assert_equal [JASON, JZ, KEVIN].sort, server.requests.map { |r| r.path[/\d+\z/].to_i }.map { |id| expected[id] || JZ }.sort
    refute_includes paths, "/push/56887440" # the author
    assert_nil expected[gone], "410 destroys the subscription"

    push = open_push(server.requests.find { |r| r.path.end_with?("/#{expected.key(KEVIN)}") })
    assert_equal "Designers", push["title"]
    assert_equal "David: hey @Kevin look", push["options"]["body"]
    assert_equal "/account/logo", push["options"]["icon"]
    assert_equal "/rooms/#{DESIGNERS}", push["options"]["data"]["path"]
    assert_equal db.query_single_splat("SELECT COUNT(*) FROM memberships WHERE user_id = ? AND unread_at IS NOT NULL", KEVIN), push["options"]["data"]["badge"]
    assert_operator push["options"]["data"]["badge"], :>=, 1
    # unread_memberships: everyone visible and disconnected except the author
    assert_equal message.created_at, db.query_single_splat("SELECT unread_at FROM memberships WHERE room_id = ? AND user_id = ?", DESIGNERS, JASON)
    assert_nil db.query_single_splat("SELECT unread_at FROM memberships WHERE room_id = ? AND user_id = ?", DESIGNERS, DAVID)
  ensure
    server&.close
  end

  def test_push_message_direct_room_payload_and_connected_users_skipped
    room = Campfire::Room.find(db, 699448329) # David, Jason, JZ, Kevin (direct)
    server = FakeHTTP.new { [201, {}, ""] }
    point_subscriptions_at(server)
    db.execute("UPDATE memberships SET connected_at = ? WHERE room_id = ? AND user_id = ?", Campfire::Clock.now_db, room.id, JZ)
    kevin = Campfire::User.new(*db.query_single_array("SELECT #{Campfire::User::COLS} FROM users WHERE id = ?", KEVIN))
    message = Campfire::Message.create!(db, room, kevin, body: "<div>psst</div>")
    Campfire::PushMessageJob.perform(room.id, message.id)
    subs = db.query_array("SELECT id, user_id FROM push_subscriptions").to_h
    users = server.requests.map { |r| subs[r.path[/\d+\z/].to_i] }.sort
    assert_equal [DAVID, DAVID, JASON].sort, users # both of David's subscriptions; JZ is connected; Kevin wrote it
    push = open_push(server.requests.first)
    assert_equal "Kevin", push["title"]
    assert_equal "psst", push["options"]["body"]
  ensure
    server&.close
  end

  def test_push_message_destroys_subscriptions_with_invalid_keys
    room = Campfire::Room.find(db, DESIGNERS)
    server = FakeHTTP.new { [201, {}, ""] }
    point_subscriptions_at(server)
    jason = db.query_single_splat("SELECT id FROM push_subscriptions WHERE user_id = ?", JASON)
    db.execute("UPDATE push_subscriptions SET p256dh_key = '456-RIXcMgkdjhRnFZaYjjGvo00dydRQbCpQTuXFjLaCPSE7ofxi19awgGc3Doqa1RmYQqsbQDfQTifFZgc' WHERE id = ?", jason)
    david = Campfire::User.new(*db.query_single_array("SELECT #{Campfire::User::COLS} FROM users WHERE id = ?", DAVID))
    message = Campfire::Message.create!(db, room, david, body: "<div>hi</div>")
    Campfire::PushMessageJob.perform(room.id, message.id)
    assert_nil db.query_single_splat("SELECT id FROM push_subscriptions WHERE id = ?", jason)
    refute_includes server.requests.map(&:path), "/push/#{jason}"
  ensure
    server&.close
  end

  def test_push_test_delivers_and_reports
    server = FakeHTTP.new { [201, {}, ""] }
    point_subscriptions_at(server)
    sub = db.query_single_splat("SELECT id FROM push_subscriptions WHERE user_id = ? ORDER BY id LIMIT 1", DAVID)
    assert_equal :delivered, Campfire::PushTestJob.perform(DAVID, sub, "http://example.com/users/me/push_subscriptions")
    push = open_push(server.requests.last)
    assert_equal "Campfire Test", push["title"]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, push["options"]["body"])
    assert_equal "http://example.com/users/me/push_subscriptions", push["options"]["data"]["path"]
    assert_equal :not_found, Campfire::PushTestJob.perform(KEVIN, sub, "x")
    assert_equal :delivered, Campfire::PushTestNotificationJob.perform(sub, "Campfire Test", "b0dy", "http://h/users/me/push_subscriptions")
    push = open_push(server.requests.last)
    assert_equal ["Campfire Test", "b0dy", "http://h/users/me/push_subscriptions"], [push["title"], push["options"]["body"], push["options"]["data"]["path"]]
    @resolved = nil
    assert_equal :skipped, Campfire::PushTestJob.perform(DAVID, sub, "x")
  ensure
    server&.close
  end

  def with_bot_server(reply)
    server = FakeHTTP.new { |req| reply.respond_to?(:call) ? reply.call(req) : reply }
    db.execute("UPDATE webhooks SET url = ? WHERE user_id = ?", "http://127.0.0.1:#{server.port}/bender", BENDER)
    @resolved = nil # no pushes
    yield server
  ensure
    server&.close
  end

  def last_message(room_id)
    id = db.query_single_splat("SELECT id FROM messages WHERE room_id = ? ORDER BY id DESC LIMIT 1", room_id)
    Campfire::Message.load_one(db, id)
  end

  def test_webhook_payload_and_text_reply
    with_bot_server([200, { "content-type" => "text/plain; charset=utf-8" }, "Hello <b>Kevin</b> & co"]) do |server|
      room = Campfire::Room.find(db, KEVIN_BENDER)
      kevin = Campfire::User.new(*db.query_single_array("SELECT #{Campfire::User::COLS} FROM users WHERE id = ?", KEVIN))
      message = Campfire::Message.create!(db, room, kevin, body: "<div>@Bender Bot  do <the> thing </div>")
      assert_equal [BENDER], Campfire::Delivery.deliver_webhooks(db, room, message)

      req = server.requests.last
      assert_equal "POST", req.method
      assert_equal "/bender", req.path
      assert_equal "application/json", req.headers["content-type"]
      payload = JSON.parse(req.body)
      assert_equal({ "id" => KEVIN, "name" => "Kevin" }, payload["user"])
      assert_equal({ "id" => KEVIN_BENDER, "name" => nil, "path" => "/rooms/#{KEVIN_BENDER}/#{BENDER}-BenderBot123/messages" }, payload["room"])
      assert_equal message.id, payload["message"]["id"]
      assert_equal "<div>@Bender Bot  do <the> thing </div>", payload["message"]["body"]["html"]
      assert_equal "/rooms/#{KEVIN_BENDER}/@#{message.id}", payload["message"]["path"]
      refute_includes req.body, "<", "ActiveSupport::JSON escapes <"

      reply = last_message(KEVIN_BENDER)
      refute_equal message.id, reply.id
      assert_equal BENDER, reply.creator_id
      assert_equal "Hello <b>Kevin</b> & co", reply.body
      assert @broadcasts.any? { |s, j| s == "user_#{KEVIN}_unreads" && j == %({"roomId":#{KEVIN_BENDER}}) }
      assert @broadcasts.any? { |s, _| s == "user_#{BENDER}_unreads" }
    end
  end

  def test_webhook_plain_strips_recipient_mention
    with_bot_server([204, {}, ""]) do |server|
      room = Campfire::Room.find(db, 486777696) # All Talk: Jason, David, Bender (mentions)
      david = Campfire::User.new(*db.query_single_array("SELECT #{Campfire::User::COLS} FROM users WHERE id = ?", DAVID))
      before = last_message(room.id).id
      message = Campfire::Message.create!(db, room, david, body: mention(BENDER, "Bender Bot"))
      assert_equal [BENDER], Campfire::Delivery.deliver_webhooks(db, room, message)
      assert_equal "hey  look", JSON.parse(server.requests.last.body)["message"]["body"]["plain"]
      assert_equal message.id, last_message(room.id).id, "no reply for a 204 without content type"
      plain = Campfire::Message.create!(db, room, david, body: "<div>no mention</div>")
      assert_equal [], Campfire::Delivery.deliver_webhooks(db, room, plain)
      refute_equal before, message.id
    end
  end

  def test_webhook_attachment_reply
    png = File.binread(Dir[File.join(JobsHarness::ROOT, "**/*.png")].reject { |f| f.include?("/tmp/") }.first)
    with_bot_server([200, { "content-type" => "image/png" }, png]) do
      room = Campfire::Room.find(db, KEVIN_BENDER)
      Campfire::WebhookJob.perform(BENDER, last_message(KEVIN_BENDER).id)
      reply = last_message(KEVIN_BENDER)
      assert_equal BENDER, reply.creator_id
      assert_equal "attachment.png", reply.attachment.filename
      assert_equal "image/png", reply.attachment.content_type
      assert_equal png.bytesize, reply.attachment.byte_size
      assert_equal "attachment.png", reply.plain_text_body
    end
  end

  def test_webhook_unknown_reply_type_and_error_status
    with_bot_server(->(req) { [500, { "content-type" => "text/plain" }, "boom"] }) do
      before = last_message(KEVIN_BENDER).id
      Campfire::WebhookJob.perform(BENDER, before)
      reply = last_message(KEVIN_BENDER)
      # 500 text/plain is not a text reply; it is a registered type, so it becomes an attachment
      assert_equal "attachment.text", reply.attachment&.filename
    end
    with_bot_server([200, { "content-type" => "bogus type!" }, "x"]) do
      before = last_message(KEVIN_BENDER).id
      Campfire::WebhookJob.perform(BENDER, before)
      assert_equal before, last_message(KEVIN_BENDER).id
    end
  end

  def test_webhook_timeout_posts_failure_text
    old = Campfire::WebhookJob::TIMEOUT
    Campfire::WebhookJob.send(:remove_const, :TIMEOUT)
    Campfire::WebhookJob.const_set(:TIMEOUT, 0.3)
    with_bot_server(->(req) { sleep 1; [200, { "content-type" => "text/plain" }, "late"] }) do
      Campfire::WebhookJob.perform(BENDER, last_message(KEVIN_BENDER).id)
      assert_equal "Failed to respond within 7 seconds", last_message(KEVIN_BENDER).body
    end
  ensure
    Campfire::WebhookJob.send(:remove_const, :TIMEOUT)
    Campfire::WebhookJob.const_set(:TIMEOUT, old)
  end

  def test_media_type_and_mime_lookup
    j = Campfire::WebhookJob
    assert_equal "text/plain", j.media_type(" text/plain ; charset=utf-8")
    assert_equal %w[jpeg image/jpeg], j.mime_lookup("image/jpeg")
    assert_equal %w[json application/json], j.mime_lookup("application/problem+json")
    assert_equal ["", "application/x-thing"], j.mime_lookup("application/x-thing")
    assert_nil j.mime_lookup("bogus type!")
  end
end
