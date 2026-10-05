# frozen_string_literal: true

# The bot API: Messages::ByBotsController and Messages::Boosts::ByBotsController
# (upstream test/controllers/messages/by_bots_controller_test.rb and
# messages/boosts/by_bots_controller_test.rb, against the seed instead of the
# fixtures), plus byte-for-byte pages captured from the Rails reference on the
# same seed (test/fixtures/bot_api).
require "minitest/autorun"
require "json"
require_relative "support/app_harness"

AppHarness.boot!

class BotApiTest < Minitest::Test
  BENDER = 394959859
  BENDER_KEY = "394959859-BenderBot123"
  KEVIN = 712064548
  JZ = 773523953
  WATERCOOLER = 486777696
  DESIGNERS = 654632876
  BENDER_AND_KEVIN = 340026324
  FIRST = 309456473        # in designers
  FOURTH = 933434481       # jz's, in watercooler
  TENTH = 217777555
  THIRTEENTH = 136976342
  BUSY_060 = 933434569
  FOURTH_BY_BENDER = 329428235
  BOOST_THIRTEENTH = 136976342 # jason's, on thirteenth
  BASE = "http://#{AppHarness::HOST}".freeze
  FIXTURES = File.join(__dir__, "fixtures/bot_api")

  # A bot's request: no cookies, the raw body (form-encoded by default, as the
  # Rails integration tests and curl -d send it).
  def bot(method, path, body = nil, type = "application/x-www-form-urlencoded", headers = {})
    h = Protocol::HTTP::Headers.new
    h.add("user-agent", "curl/8.5.0")
    h.add("accept", "*/*")
    h.add("content-type", type) if body
    headers.each { |k, v| h.add(k, v) }
    req = Protocol::HTTP::Request.new("http", AppHarness::HOST, method, path, "HTTP/1.1", h, body && Protocol::HTTP::Body::Buffered.wrap(body.b))
    res = AppHarness.app.call(req)
    rh = {}
    res.headers.each { |k, v| rh[k] = v.to_s }
    AppHarness::Response.new(res.status, rh, (res.body ? res.body.join.to_s : +"").force_encoding(Encoding::UTF_8))
  end

  def messages_path(room = WATERCOOLER, key = BENDER_KEY) = "/rooms/#{room}/#{key}/messages"
  def boosts_path(message, room = WATERCOOLER, key = BENDER_KEY) = "#{messages_path(room, key)}/#{message}/boosts"

  def db = AppHarness.db
  def message_count = db.query_single_splat("SELECT count(*) FROM messages")
  def boost_count = db.query_single_splat("SELECT count(*) FROM boosts")
  def last_message_id = db.query_single_splat("SELECT id FROM messages ORDER BY id DESC LIMIT 1")
  def load_message(id) = Campfire::Message.load_one(db, id)
  def plain_text(id) = load_message(id).plain_text_body
  def room_ids(room, sql_tail = "", *binds)
    db.query_array("SELECT id FROM messages WHERE room_id = ? #{sql_tail}", room, *binds).flatten
  end

  def setup
    AppHarness.captured.clear
  end

  def post_bot_message(body)
    r = bot("POST", messages_path, body)
    assert_equal 201, r.status
    r.headers["location"][%r{/messages/(\d+)\z}, 1].to_i
  end

  def webhook_jobs = AppHarness.captured.select { |c| c[0] == :job && c[1] == :webhook }
  def broadcasts(stream_part) = AppHarness.captured.select { |c| c[0] == :broadcast && c[1].to_s.include?(stream_part) }

  # ---- Messages::ByBotsController -------------------------------------------

  # Falcon hands the request path over as ASCII-8BIT; the key must still match
  # the TEXT bot_token column.
  def test_index_with_a_binary_request_path_authenticates_the_bot
    res = bot("GET", messages_path.b)
    assert_equal 200, res.status
    assert_equal "application/json; charset=utf-8", res.headers["content-type"]
  end

  def test_create
    before = message_count
    r = bot("POST", messages_path, "Hello Bot World!")
    assert_equal 201, r.status
    assert_equal "", r.body
    id = last_message_id
    assert_equal "#{BASE}/messages/#{id}", r.headers["location"]
    assert_equal before + 1, message_count
    assert_equal "Hello Bot World!", plain_text(id)
    assert_equal BENDER, load_message(id).creator_id
    refute_empty broadcasts("messages")
  end

  def test_create_with_utf8_content_and_a_plain_text_body
    id = post_bot_message("Hello 👋!")
    assert_equal "Hello 👋!", plain_text(id)
    r = bot("POST", messages_path, "Plain 🤖", "text/plain")
    assert_equal 201, r.status
    assert_equal "Plain 🤖", plain_text(last_message_id)
  end

  def test_create_file
    before = message_count
    boundary = "----botapi"
    data = File.binread(File.join(__dir__, "fixtures/moon.jpg"))
    body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"attachment\"; filename=\"moon.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".b +
      data.b + "\r\n--#{boundary}--\r\n".b
    r = bot("POST", messages_path, body, "multipart/form-data; boundary=#{boundary}")
    assert_equal 201, r.status
    assert_equal before + 1, message_count
    id = last_message_id
    assert db.query_single_splat("SELECT 1 FROM active_storage_attachments WHERE record_type = 'Message' AND record_id = ? AND name = 'attachment'", id)
  end

  def test_create_does_not_trigger_a_webhook_to_the_sending_bot_if_it_mentions_itself
    sgid = Campfire.secrets.attachable_sgid("User", BENDER)
    id = post_bot_message(%(<div>Hey <action-text-attachment sgid="#{sgid}" content-type="application/vnd.campfire.mention"></action-text-attachment></div>))
    assert_includes db.query_single_splat("SELECT body FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ?", id), sgid
    assert_empty webhook_jobs.select { |j| j[2] == BENDER }
  end

  def test_direct_room_index_matches_the_reference_and_create_does_not_trigger_a_webhook_to_itself
    r = bot("GET", messages_path(BENDER_AND_KEVIN))
    assert_equal 200, r.status
    assert_equal File.read(File.join(FIXTURES, "rails_direct.json")), r.body
    assert_equal "1", r.headers["x-total-count"]
    assert_nil r.headers["link"]

    assert_equal 201, bot("POST", messages_path(BENDER_AND_KEVIN), "Talking to myself again!").status
    assert_empty webhook_jobs
  end

  def test_create_without_a_body_or_attachment
    before = message_count
    r = bot("POST", messages_path)
    assert_equal 422, r.status
    assert_equal 422, bot("POST", messages_path, "   ").status
    assert_equal before, message_count
  end

  def test_create_cant_be_abused_to_post_messages_as_any_user
    before = message_count
    r = bot("POST", messages_path(BENDER_AND_KEVIN, "#{KEVIN}-"), "Hello 👋!")
    assert_equal 302, r.status
    assert_equal "#{BASE}/session/new", r.headers["location"]
    assert_equal before, message_count
  end

  def test_index_returns_the_last_page_in_the_order_sent
    r = bot("GET", messages_path)
    assert_equal 200, r.status
    assert_equal "application/json; charset=utf-8", r.headers["content-type"]
    json = JSON.parse(r.body)
    expected = room_ids(WATERCOOLER, "ORDER BY created_at DESC LIMIT 40").reverse
    assert_equal expected, json.map { _1["id"] }
    assert_equal room_ids(WATERCOOLER).size.to_s, r.headers["x-total-count"]
    assert_equal %(<#{BASE}/rooms/#{WATERCOOLER}/#{BENDER_KEY}/messages?before=#{expected.first}>; rel="next"), r.headers["link"]
  end

  def test_index_includes_message_details
    id = post_bot_message("Hello from Bender!")
    json = JSON.parse(bot("GET", messages_path).body).last
    m = load_message(id)
    assert_equal id, json["id"]
    assert_equal "Hello from Bender!", json["body"]["plain_text"]
    assert_includes json["body"]["html"], "Hello from Bender!"
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, json["created_at"])
    assert_equal m.created_at[0, 10], json["created_at"][0, 10]
    assert_equal BENDER, json["creator"]["id"]
    assert_equal "Bender Bot", json["creator"]["name"]
    assert_equal "bot", json["creator"]["role"]
    assert_match %r{\A#{BASE}/users/[^/]+/avatar\?v=\d+\z}, json["creator"]["avatar_url"]
    assert_equal({ "id" => WATERCOOLER }, json["room"])
    assert_equal "#{BASE}/rooms/#{WATERCOOLER}/messages/#{id}", json["url"]
  end

  def test_index_pages_match_the_reference
    r = bot("GET", "#{messages_path}?before=#{BUSY_060}")
    assert_equal 200, r.status
    assert_equal File.read(File.join(FIXTURES, "rails_before.json")), r.body
    first = JSON.parse(r.body).first["id"]
    assert_equal %(<#{BASE}/rooms/#{WATERCOOLER}/#{BENDER_KEY}/messages?before=#{first}>; rel="next"), r.headers["link"]

    r = bot("GET", "#{messages_path}?after=#{BUSY_060}")
    assert_equal 200, r.status
    assert_equal File.read(File.join(FIXTURES, "rails_after.json")), r.body
    last = JSON.parse(r.body).last["id"]
    assert_equal %(<#{BASE}/rooms/#{WATERCOOLER}/#{BENDER_KEY}/messages?after=#{last}>; rel="next"), r.headers["link"]
  end

  def test_index_pages_through_older_messages_with_the_link_header
    seen = []
    path = messages_path
    pages = 0
    while path
      r = bot("GET", path)
      assert_equal 200, r.status
      ids = JSON.parse(r.body).map { _1["id"] }
      assert_operator ids.size, :<=, 40
      seen.unshift(*ids)
      path = r.headers["link"]&.[](/<#{Regexp.escape(BASE)}(.*)>/, 1)
      pages += 1
    end
    assert_operator pages, :>, 1
    assert_equal room_ids(WATERCOOLER, "ORDER BY created_at, id"), seen
  end

  def test_index_pages_newer_messages_with_after
    r = bot("GET", "#{messages_path}?after=#{TENTH}")
    assert_equal 200, r.status
    tenth_at = db.query_single_splat("SELECT created_at FROM messages WHERE id = ?", TENTH)
    expected = room_ids(WATERCOOLER, "AND created_at > ? ORDER BY created_at LIMIT 40", tenth_at)
    assert_equal expected, JSON.parse(r.body).map { _1["id"] }
  end

  def test_index_with_an_unknown_before_is_a_json_not_found
    r = bot("GET", "#{messages_path}?before=1")
    assert_equal 404, r.status
    assert_equal "application/json; charset=UTF-8", r.headers["content-type"]
    assert_equal %({"status":404,"error":"Not Found"}), r.body
  end

  def test_index_requires_a_valid_bot_key
    r = bot("GET", messages_path(WATERCOOLER, "invalid-bot-key"))
    assert_equal 302, r.status
    assert_equal "#{BASE}/session/new", r.headers["location"]
    assert_equal 302, bot("GET", messages_path(WATERCOOLER, "#{BENDER}-wrong")).status
  end

  def test_a_bot_key_with_extra_dashes_matches_on_its_first_two_parts
    assert_equal 200, bot("GET", messages_path(WATERCOOLER, "#{BENDER_KEY}-anything")).status
  end

  def test_index_is_not_found_for_a_room_the_bot_is_not_a_member_of
    r = bot("GET", messages_path(DESIGNERS))
    assert_equal 404, r.status
    assert_equal "text/html", r.headers["content-type"]
    assert_equal "", r.body
  end

  def test_create_is_not_found_for_a_room_the_bot_is_not_a_member_of
    before = message_count
    assert_equal 404, bot("POST", messages_path(DESIGNERS), "Hello!").status
    assert_equal before, message_count
  end

  def test_regular_messages_index_remains_denied_for_bots
    assert_equal 403, bot("GET", "/rooms/#{WATERCOOLER}/messages?bot_key=#{BENDER_KEY}").status
  end

  def test_update
    id = post_bot_message("Deploying...")
    before = message_count
    AppHarness.captured.clear
    r = bot("PATCH", "#{messages_path}/#{id}", "Deployed.")
    assert_equal 200, r.status
    assert_equal "application/json; charset=utf-8", r.headers["content-type"]
    assert_equal before, message_count
    assert_equal "Deployed.", plain_text(id)
    json = JSON.parse(r.body)
    assert_equal id, json["id"]
    assert_equal "Deployed.", json["body"]["plain_text"]
    assert_equal BENDER, json["creator"]["id"]
    assert_equal "#{BASE}/rooms/#{WATERCOOLER}/messages/#{id}", json["url"]
    refute_empty broadcasts("messages")
    # The index serves the edited message, not a stale fragment.
    assert_equal "Deployed.", JSON.parse(bot("GET", messages_path).body).find { _1["id"] == id }["body"]["plain_text"]
  end

  def test_update_with_utf8_content_and_put
    id = post_bot_message("Deploying...")
    r = bot("PUT", "#{messages_path}/#{id}", "Deployed 🚀!")
    assert_equal 200, r.status
    assert_equal "Deployed 🚀!", plain_text(id)
    assert_equal "Deployed 🚀!", JSON.parse(r.body)["body"]["plain_text"]
  end

  # bot_api/ parity state: a JSON body is stored as it was sent.
  def test_update_with_a_json_body_stores_it_raw
    id = post_bot_message("Deploying...")
    raw = %({"message":{"body":"Deployed via JSON"}})
    r = bot("PATCH", "#{messages_path}/#{id}", raw, "application/json")
    assert_equal 200, r.status
    assert_equal raw, plain_text(id)
  end

  def test_update_cant_touch_a_message_the_bot_did_not_create
    original = plain_text(FOURTH)
    r = bot("PATCH", "#{messages_path}/#{FOURTH}", "Hijacked!")
    assert_equal 403, r.status
    assert_equal original, plain_text(FOURTH)
  end

  def test_update_is_not_found_for_a_room_the_bot_is_not_a_member_of
    original = plain_text(FIRST)
    assert_equal 404, bot("PATCH", "#{messages_path(DESIGNERS)}/#{FIRST}", "Hijacked!").status
    assert_equal original, plain_text(FIRST)
  end

  def test_update_of_a_message_outside_the_room_is_a_json_not_found
    r = bot("PATCH", "#{messages_path}/#{FIRST}", "Hijacked!")
    assert_equal 404, r.status
    assert_equal %({"status":404,"error":"Not Found"}), r.body
  end

  def test_update_cant_be_abused_to_edit_messages_as_any_user
    original = plain_text(FOURTH)
    assert_equal 302, bot("PATCH", "#{messages_path(WATERCOOLER, "#{JZ}-")}/#{FOURTH}", "Hijacked!").status
    assert_equal original, plain_text(FOURTH)
  end

  def test_destroy
    id = post_bot_message("Deploying...")
    before = message_count
    AppHarness.captured.clear
    r = bot("DELETE", "#{messages_path}/#{id}")
    assert_equal 204, r.status
    assert_equal before - 1, message_count
    refute_empty broadcasts("messages")
  end

  def test_destroy_cant_touch_a_message_the_bot_did_not_create
    before = message_count
    assert_equal 403, bot("DELETE", "#{messages_path}/#{FOURTH}").status
    assert_equal before, message_count
  end

  # ---- Messages::Boosts::ByBotsController -----------------------------------

  def test_boost_create_adds_a_boost_and_returns_it
    before = boost_count
    r = bot("POST", boosts_path(FOURTH), "👀")
    assert_equal 201, r.status
    assert_equal "application/json; charset=utf-8", r.headers["content-type"]
    assert_equal before + 1, boost_count
    id, content, booster = db.query_single_array("SELECT id, content, booster_id FROM boosts WHERE message_id = ? ORDER BY id DESC LIMIT 1", FOURTH)
    assert_equal "👀", content
    assert_equal BENDER, booster
    json = JSON.parse(r.body)
    assert_equal %w[id content created_at booster message], json.keys
    assert_equal id, json["id"]
    assert_equal "👀", json["content"]
    assert_equal BENDER, json["booster"]["id"]
    assert_equal({ "id" => FOURTH, "url" => "#{BASE}/rooms/#{WATERCOOLER}/messages/#{FOURTH}" }, json["message"])
  end

  def test_boost_create_with_text_content_and_a_plain_text_body
    assert_equal 201, bot("POST", boosts_path(FOURTH), "Nice!").status
    assert_equal "Nice!", db.query_single_splat("SELECT content FROM boosts WHERE message_id = ? ORDER BY id DESC LIMIT 1", FOURTH)
    assert_equal 201, bot("POST", boosts_path(FOURTH), "🤖", "text/plain").status
    assert_equal "🤖", db.query_single_splat("SELECT content FROM boosts WHERE message_id = ? ORDER BY id DESC LIMIT 1", FOURTH)
  end

  def test_boost_create_broadcasts_the_boost
    bot("POST", boosts_path(FOURTH), "👍")
    assert_equal 1, broadcasts("messages").size
  end

  def test_boost_create_without_content
    before = boost_count
    assert_equal 422, bot("POST", boosts_path(FOURTH)).status
    assert_equal 422, bot("POST", boosts_path(FOURTH), "   ").status
    assert_equal before, boost_count
  end

  def test_boost_create_requires_a_valid_bot_key
    before = boost_count
    assert_equal 302, bot("POST", boosts_path(FOURTH, WATERCOOLER, "invalid-bot-key"), "👀").status
    assert_equal before, boost_count
  end

  def test_boost_create_is_not_found_for_a_room_the_bot_is_not_a_member_of
    before = boost_count
    r = bot("POST", boosts_path(FIRST, DESIGNERS), "👀")
    assert_equal 404, r.status
    assert_equal "text/html", r.headers["content-type"]
    assert_equal before, boost_count
  end

  def test_boost_create_is_not_found_for_a_message_outside_the_room
    before = boost_count
    assert_equal 404, bot("POST", boosts_path(FIRST), "👀").status
    assert_equal before, boost_count
  end

  def test_boost_create_cant_be_abused_to_post_boosts_as_a_regular_user
    before = boost_count
    assert_equal 302, bot("POST", boosts_path(FOURTH, WATERCOOLER, "#{KEVIN}-"), "👀").status
    assert_equal before, boost_count
  end

  def test_boost_destroy_removes_the_bots_own_boost_and_broadcasts
    id = db.query_single_splat("SELECT id FROM boosts WHERE id = ?", FOURTH_BY_BENDER) || begin
      bot("POST", boosts_path(FOURTH), "👀")
      db.query_single_splat("SELECT id FROM boosts WHERE booster_id = ? ORDER BY id DESC LIMIT 1", BENDER)
    end
    AppHarness.captured.clear
    before = boost_count
    r = bot("DELETE", "#{boosts_path(FOURTH)}/#{id}")
    assert_equal 204, r.status
    assert_equal before - 1, boost_count
    assert_equal 1, broadcasts("messages").size
  end

  def test_boost_destroy_cant_touch_a_boost_the_bot_did_not_make
    before = boost_count
    assert_equal 404, bot("DELETE", "#{boosts_path(THIRTEENTH)}/#{BOOST_THIRTEENTH}").status
    assert_equal before, boost_count
  end

  def test_boost_destroy_requires_a_valid_bot_key
    before = boost_count
    assert_equal 302, bot("DELETE", "#{boosts_path(FOURTH, WATERCOOLER, "invalid-bot-key")}/#{FOURTH_BY_BENDER}").status
    assert_equal before, boost_count
  end
end
