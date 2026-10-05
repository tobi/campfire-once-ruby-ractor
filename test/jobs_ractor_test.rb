# frozen_string_literal: true

# The :webhook and :push_message handlers inside a real job Ractor (constants
# deep-frozen as at boot, async-http and DNS from a non-main Ractor).
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/campfire"
%w[storage cable multipart rich_text web_push].each { |f| require_relative "../lib/campfire/#{f}" }
require_relative "../app/helpers/users/avatars_helper"
Dir[File.expand_path("../app/models/**/*.rb", __dir__)].sort.each { |f| require f }
Dir[File.expand_path("../app/jobs/**/*.rb", __dir__)].sort.each { |f| require f }
require_relative "support/fake_http"
Minitest::Assertions.diff = nil
# Extralite 3.1.3 segfaults closing any connection that wrote to an FTS5 table
# (even :memory:), so the message search index is skipped here.
Campfire::Message.singleton_class.class_eval("def index!(_db, _message) = nil")

class JobsRactorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SECRET = "5335c3b1ad35b4ad170c3413bd651ef3b6ed64e257261871a6de3f978cf3868ee417a927040935fb30b0f7debdedb34a2a403e9f34b16cf594c917c2ecd4a995"
  KEVIN_BENDER, KEVIN, BENDER = 340026324, 712064548, 394959859

  def test_webhook_round_trip_in_job_ractor
    dir = Dir.mktmpdir("jobs-ractor")
    db_path = File.join(dir, "db.sqlite3")
    FileUtils.cp(File.join(ROOT, "tmp/seed/db/production.sqlite3"), db_path)
    config = Campfire::Config.from_env("SECRET_KEY_BASE" => SECRET, "CAMPFIRE_DATABASE_PATH" => db_path,
      "CAMPFIRE_FILES_PATH" => dir, "PORT" => "0",
      "VAPID_PUBLIC_KEY" => "BEYXTBB5_jNhNzXDmx5KEU55Vbbd-u--Lk9rM5OFQvUkPIBwZJ9QzAq0zdEzFw6yTV8cTriz_qYBVicY02_VxTQ=",
      "VAPID_PRIVATE_KEY" => "qfXLHghuG1rSHZUVo9SscNRI-0EIHRbIrfeGCqbAwak=")
    Campfire.const_set(:CONFIG, Ractor.make_shareable(config))
    Campfire.const_set(:SECRETS, Campfire::RailsCompat::Secrets.new(SECRET))
    RactorCompat.share_constants!(extra_roots: [Campfire, Extralite, ERB, OpenSSL])

    server = FakeHTTP.new { [200, { "content-type" => "text/html" }, "<p>beep</p>"] }
    db = Campfire::DB.connection
    db.execute("UPDATE webhooks SET url = ? WHERE user_id = ?", "http://localhost:#{server.port}/hook", BENDER)
    db.execute("DELETE FROM push_subscriptions") # no real push services
    msg = db.query_single_splat("SELECT max(id) FROM messages WHERE room_id = ?", KEVIN_BENDER)

    Campfire::Log.start
    Campfire::Jobs.start(1, config)
    reply = Campfire::Jobs.call(:webhook, BENDER, msg)
    refute_nil reply, "job raised (see stderr)"
    assert_equal 1, server.requests.size
    assert_equal msg, JSON.parse(server.requests[0].body)["message"]["id"]
    row = db.query_single_array("SELECT m.creator_id, r.body FROM messages m JOIN action_text_rich_texts r ON r.record_id = m.id AND r.record_type = 'Message' WHERE m.room_id = ? ORDER BY m.id DESC LIMIT 1", KEVIN_BENDER)
    assert_equal [BENDER, "<p>beep</p>"], row
    # push_message for the reply ran in the job Ractor too (no subscriptions: no-op)
    assert_equal 0, Campfire::Jobs.call(:push_message, KEVIN_BENDER, db.query_single_splat("SELECT max(id) FROM messages"))
  ensure
    server&.close
  end
end
