# frozen_string_literal: true

require "minitest/autorun"
require_relative "support/app_harness"

AppHarness.boot!

# Pure helpers and model math.
class MessageHelpersTest < Minitest::Test
  M = Campfire::Message

  def view
    o = Object.new
    o.extend(Campfire::Helpers)
    o
  end

  def test_time_bind_drops_zero_usec_like_rails
    assert_equal "2026-02-28 18:44:00", M.time_bind("2026-02-28 18:44:00.000000")
    assert_equal "2026-02-28 18:44:00.120000", M.time_bind("2026-02-28 18:44:00.120000")
    assert_equal "2026-02-28 18:44:00", M.time_bind_from_ms(1_772_304_240_000)
    assert_equal "2026-02-28 18:44:00.123000", M.time_bind_from_ms(1_772_304_240_123)
    assert_equal "1970-01-01 00:00:00", M.time_bind_from_ms(0)
    assert_equal "2026-02-28 18:44:00", M.time_bind_from_time(Time.utc(2026, 2, 28, 18, 44, 0))
    assert_equal "2026-02-28 18:44:00.000500", M.time_bind_from_time(Time.utc(2026, 2, 28, 18, 44, 0, 500))
  end

  def test_version_matches_sql_version
    db = AppHarness.db
    rows = db.query_array("SELECT m.updated_at, #{M::VERSION} FROM messages m LIMIT 50")
    refute_empty rows
    rows.each { |updated_at, v| assert_equal v, M.version(updated_at), updated_at }
    assert_equal 1_772_304_240_120_000, M.version("2026-02-28 18:44:00.120000")
  end

  def test_to_sentence
    v = view
    assert_equal "", v.to_sentence([])
    assert_equal "a", v.to_sentence(%w[a])
    assert_equal "a and b", v.to_sentence(%w[a b])
    assert_equal "a, b, and c", v.to_sentence(%w[a b c])
  end

  def test_turbo_stream_tag_serialization
    v = view
    assert_equal %(<turbo-stream action="append" target="messages_rooms_open_1"><template><p>x</p></template></turbo-stream>),
      v.turbo_stream_tag("append", "messages_rooms_open_1", "<p>x</p>")
    assert_equal %(<turbo-stream maintain_scroll="true" action="replace" target="presentation_message_a&amp;b"><template></template></turbo-stream>),
      v.turbo_stream_tag("replace", "presentation_message_a&b", "", maintain_scroll: true)
    assert_equal %(<turbo-stream action="remove" target="message_x"></turbo-stream>), v.turbo_stream_tag("remove", "message_x")
  end

  def test_next_involvement_cycles
    v = view
    open = Campfire::Room.new(1, "x", "Rooms::Open", 1, nil, nil)
    direct = Campfire::Room.new(2, nil, "Rooms::Direct", 1, nil, nil)
    assert_equal "everything", v.next_involvement_for(open, "mentions")
    assert_equal "mentions", v.next_involvement_for(open, "invisible")
    assert_equal "nothing", v.next_involvement_for(direct, "everything")
    assert_equal "everything", v.next_involvement_for(direct, "nothing")
  end
end

# Message::Pagination against the seed.
class MessagePaginationTest < Minitest::Test
  M = Campfire::Message
  ROOM = 486777696

  def db = AppHarness.db

  def ordered_ids = db.query_splat("SELECT id FROM messages WHERE room_id = ? ORDER BY created_at, id", ROOM)

  def test_last_page_is_newest_forty_oldest_first
    page = M.last_page(db, ROOM)
    assert_equal M::PAGE_SIZE, page.size
    assert_equal ordered_ids.last(40), page.ids
  end

  def test_page_before_and_after
    all = ordered_ids
    created = ->(id) { db.query_single_splat("SELECT created_at FROM messages WHERE id = ?", id) }
    pivot = all[60]
    before = M.page_before(db, ROOM, created.(pivot))
    after = M.page_after(db, ROOM, created.(pivot))
    times = ->(ids) { ids.map { |i| created.(i) } }
    assert times.(before.ids).all? { |t| t < created.(pivot) }
    assert times.(after.ids).all? { |t| t > created.(pivot) }
    assert_equal times.(before.ids).sort, times.(before.ids)
    assert_equal times.(after.ids).sort, times.(after.ids)
    assert_operator before.size, :<=, 40
    assert_operator after.size, :<=, 40
  end

  def test_page_around_includes_message_in_the_middle
    all = ordered_ids
    m = M.find_in_room(db, ROOM, all[60])
    page = M.page_around(db, m)
    assert_includes page.ids, m.id
    assert_equal page.ids.size, page.versions.size
    assert_equal M.version(m.updated_at), page.versions[page.ids.index(m.id)]
  end

  def test_paged
    assert M.paged?(db, ROOM)
    assert_equal false, M.paged?(db, 104393281)
  end
end

# The request cycle: renders, writes, broadcasts, jobs.
class MessagesFlowTest < Minitest::Test
  ROOM = 104393281 # All Pets, Rooms::Open, David is a member

  def setup
    @c = AppHarness::Client.new
    @c.csrf!
    AppHarness.captured.clear
  end

  def db = AppHarness.db

  def test_index_404_204_and_etag
    assert_equal 404, @c.get("/rooms/1/messages").status
    assert_equal 404, @c.get("/rooms/486777696/messages?before=1").status
    last = db.query_single_splat("SELECT id FROM messages WHERE room_id = 486777696 ORDER BY created_at DESC LIMIT 1")
    assert_equal 204, @c.get("/rooms/486777696/messages?after=#{last}").status
    r = @c.get("/rooms/486777696/messages")
    assert_equal 200, r.status
    assert r.body.start_with?("\n  <div id=\"message_")
    assert r.body.end_with?("</div>\n")
    etag = r.headers["etag"]
    assert_match(/\AW\/"\h{32}"\z/, etag)
    assert_equal 304, @c.get("/rooms/486777696/messages", "if-none-match" => etag).status
  end

  def test_create_update_destroy_with_broadcasts_and_jobs
    r = @c.form("POST", "/rooms/#{ROOM}/messages",
      "message[body]" => "<p>Hello from the test</p>", "message[client_message_id]" => "aaaaaaaa-0000-0000-0000-000000000001")
    assert_equal 200, r.status
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", r.headers["content-type"]
    assert r.body.start_with?(%(<turbo-stream action="append" target="messages_rooms_open_#{ROOM}"><template>\n  <div id="message_aaaaaaaa-0000-0000-0000-000000000001"))
    assert r.body.end_with?("</template></turbo-stream>\n")
    assert_includes r.body, "<p>Hello from the test</p>"
    id = db.query_single_splat("SELECT id FROM messages WHERE client_message_id = 'aaaaaaaa-0000-0000-0000-000000000001'")
    assert id
    assert_equal "<p>Hello from the test</p>", db.query_single_splat("SELECT body FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ?", id)
    assert_equal "Hello from the test", db.query_single_splat("SELECT body FROM message_search_index WHERE rowid = ?", id)

    cap = AppHarness.captured
    room = Campfire::Room.find(db, ROOM)
    stream = Campfire::Cable.room_messages_stream(room.type, room.id)
    append = cap.find { |e| e[0] == :broadcast && e[1] == stream }
    assert append, cap.inspect
    assert_equal r.body.chomp, append[2]
    # Rendered as broadcast_create does (ApplicationController.renderer with
    # Current.request): no form tokens, request host without port. That render
    # is the cached fragment later pages reuse.
    refute_includes r.body, "authenticity_token"
    assert_includes r.body, %(data-copy-to-clipboard-content-value="http://127.0.0.1/rooms/#{ROOM}/@#{id}")
    assert_includes @c.get("/rooms/#{ROOM}").body, %(content-value="http://127.0.0.1/rooms/#{ROOM}/@#{id}")
    assert_includes cap, [:job, :push_message, ROOM, id]
    members = room.user_ids(db)
    unread_streams = cap.select { |e| e[0] == :bus && e[1] == :cable }.map { |e| e[2] }
    assert_equal members.map { |u| Campfire::Cable.user_unreads_stream(u) }.sort, unread_streams.sort
    # Other members become unread; the creator does not.
    unread = db.query_array("SELECT user_id, unread_at IS NOT NULL FROM memberships WHERE room_id = ?", ROOM).to_h
    assert_equal 0, unread[AppHarness::DAVID]
    assert_includes unread.values, 1
    # db/triggers.sql: the insert touched the room.
    created = db.query_single_splat("SELECT created_at FROM messages WHERE id = ?", id)
    assert_equal created, db.query_single_splat("SELECT updated_at FROM rooms WHERE id = ?", ROOM)

    cap.clear
    r = @c.form("POST", "/rooms/#{ROOM}/messages/#{id}", "_method" => "patch", "message[body]" => "<p>Edited</p>")
    assert_equal 302, r.status
    assert_equal "http://#{AppHarness::HOST}/rooms/#{ROOM}/messages/#{id}", r.headers["location"]
    replace = cap.find { |e| e[0] == :broadcast && e[1] == stream }
    assert replace[2].start_with?(%(<turbo-stream maintain_scroll="true" action="replace" target="presentation_message_aaaaaaaa-0000-0000-0000-000000000001"><template><div id="presentation_message_))
    assert_includes replace[2], "<p>Edited</p>"
    show = @c.get("/rooms/#{ROOM}/messages/#{id}")
    assert_includes show.body, "<p>Edited</p>"

    cap.clear
    r = @c.form("POST", "/rooms/#{ROOM}/messages/#{id}", "_method" => "delete")
    assert_equal 200, r.status
    assert_equal %(<turbo-stream action="remove" target="message_aaaaaaaa-0000-0000-0000-000000000001"></turbo-stream>\n), r.body
    assert_equal [[:broadcast, stream, r.body.chomp]], cap.select { |e| e[0] == :broadcast }
    assert_nil db.query_single_splat("SELECT id FROM messages WHERE id = ?", id)
    assert_nil db.query_single_splat("SELECT rowid FROM message_search_index WHERE rowid = ?", id)
    assert_operator db.query_single_splat("SELECT updated_at FROM rooms WHERE id = ?", ROOM), :>, created
    assert_equal 404, @c.get("/rooms/#{ROOM}/messages/#{id}").status
  end

  def test_create_with_attachment
    png = File.binread(File.join(AppHarness::ROOT, "public/assets/campfire-icon-3d9986c5.png"))
    r = @c.multipart("/rooms/#{ROOM}/messages", { "message[client_message_id]" => "aaaaaaaa-0000-0000-0000-000000000002" },
      "message[attachment]", "pic.png", "image/png", png)
    assert_equal 200, r.status, r.body[0, 500]
    id = db.query_single_splat("SELECT id FROM messages WHERE client_message_id = 'aaaaaaaa-0000-0000-0000-000000000002'")
    blob_id = db.query_single_splat("SELECT blob_id FROM active_storage_attachments WHERE record_type = 'Message' AND record_id = ?", id)
    assert blob_id
    assert_includes AppHarness.captured, [:job_call, :process_attachment, blob_id]
    assert_includes r.body, "message__attachment"
    assert_nil db.query_single_splat("SELECT 1 FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ?", id)
    assert_equal "pic.png", db.query_single_splat("SELECT body FROM message_search_index WHERE rowid = ?", id)
  end

  def test_create_in_a_room_i_cannot_see
    r = @c.form("POST", "/rooms/1/messages", "message[body]" => "<p>x</p>")
    assert_equal 200, r.status
    assert r.body.include?("This room was deleted."), "room_not_found"
    assert_empty AppHarness.captured
  end

  def test_create_requires_csrf
    r = @c.form("POST", "/rooms/#{ROOM}/messages", { "message[body]" => "<p>x</p>" }, "x-csrf-token" => "bogus")
    assert_equal 422, r.status
  end

  def test_edit_forbidden_for_non_admin_non_creator
    # Make David a member (not admin) and pick someone else's message.
    db.execute("UPDATE users SET role = 0 WHERE id = ?", AppHarness::DAVID)
    other = db.query_single_splat("SELECT id FROM messages WHERE room_id = 486777696 AND creator_id != ? LIMIT 1", AppHarness::DAVID)
    assert_equal 403, @c.get("/rooms/486777696/messages/#{other}/edit").status
    assert_equal 403, @c.form("POST", "/rooms/486777696/messages/#{other}", "_method" => "delete").status
  ensure
    db.execute("UPDATE users SET role = 1 WHERE id = ?", AppHarness::DAVID)
  end

  # db/triggers.sql: deleting a room takes its memberships and messages, and with each message
  # its boosts, rich text and search index row.
  def test_room_destroy_cascades
    david = Campfire::User.new(*db.query_single_array("SELECT #{Campfire::User::COLS} FROM users WHERE id = ?", AppHarness::DAVID))
    room = Campfire::RoomOps.create!(db, Campfire::Room::CLOSED, "Doomed", david.id, [david.id])
    m = Campfire::Message.create!(db, room, david, body: "<p>doomed words</p>", plain_text: "doomed words")
    m.create_boost!(db, david, "x")
    Campfire::RoomOps.destroy!(db, room)
    assert_equal [0, 0, 0, 0, 0], [
      db.query_single_splat("SELECT count(*) FROM memberships WHERE room_id = ?", room.id),
      db.query_single_splat("SELECT count(*) FROM messages WHERE room_id = ?", room.id),
      db.query_single_splat("SELECT count(*) FROM boosts WHERE message_id = ?", m.id),
      db.query_single_splat("SELECT count(*) FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ?", m.id),
      db.query_single_splat("SELECT count(*) FROM message_search_index WHERE rowid = ?", m.id)
    ]
  end

  def test_boost_create_and_destroy
    mid = db.query_single_splat("SELECT id FROM messages WHERE room_id = 486777696 ORDER BY id LIMIT 1")
    cid = db.query_single_splat("SELECT client_message_id FROM messages WHERE id = ?", mid)
    r = @c.form("POST", "/messages/#{mid}/boosts", "boost[content]" => "🎉")
    assert_equal 302, r.status
    assert_equal "http://#{AppHarness::HOST}/messages/#{mid}/boosts", r.headers["location"]
    bid = db.query_single_splat("SELECT id FROM boosts WHERE message_id = ? ORDER BY id DESC LIMIT 1", mid)
    # db/triggers.sql: the boost touched its message, and that its room.
    boosted = db.query_single_splat("SELECT created_at FROM boosts WHERE id = ?", bid)
    assert_equal [boosted, boosted], db.query_single_array("SELECT m.updated_at, r.updated_at FROM messages m JOIN rooms r ON r.id = m.room_id WHERE m.id = ?", mid)
    b = AppHarness.captured.find { |e| e[0] == :broadcast }
    assert b[2].start_with?(%(<turbo-stream maintain_scroll="true" action="append" target="boosts_message_#{cid}"><template>  <div id="boost_#{bid}"))
    refute_includes b[2], "authenticity_token"
    index = @c.get("/messages/#{mid}/boosts", "turbo-frame" => "x").body
    assert_includes index, %(id="boost_#{bid}")
    # The broadcast's render is the boost's cached fragment (cache boost).
    frag = index[/<div id="boost_#{bid}".*?<\/form>/m]
    assert frag, index
    refute_includes frag, "authenticity_token"

    AppHarness.captured.clear
    assert_equal 204, @c.form("POST", "/messages/#{mid}/boosts/#{bid}", "_method" => "delete").status
    assert_equal %(<turbo-stream action="remove" target="boost_#{bid}"></turbo-stream>), AppHarness.captured.find { |e| e[0] == :broadcast }[2]
    assert_equal 404, @c.form("POST", "/messages/#{mid}/boosts/#{bid}", "_method" => "delete").status
    assert_operator db.query_single_splat("SELECT updated_at FROM messages WHERE id = ?", mid), :>, boosted
  end

  def test_involvement_update_broadcasts_visibility
    stream = "#{Campfire::RailsCompat::GID.build("User", AppHarness::DAVID).to_param}:rooms"
    r = @c.form("POST", "/rooms/#{ROOM}/involvement?involvement=invisible", "_method" => "put")
    assert_equal 302, r.status
    assert_equal "invisible", db.query_single_splat("SELECT involvement FROM memberships WHERE room_id = ? AND user_id = ?", ROOM, AppHarness::DAVID)
    assert_includes AppHarness.captured, [:broadcast, stream, %(<turbo-stream action="remove" target="list_rooms_open_#{ROOM}"></turbo-stream>)]
    AppHarness.captured.clear
    @c.form("POST", "/rooms/#{ROOM}/involvement?involvement=mentions", "_method" => "put")
    prepend = AppHarness.captured.find { |e| e[0] == :broadcast }
    assert prepend[2].start_with?(%(<turbo-stream action="prepend" target="shared_rooms"><template><a id="list_rooms_open_#{ROOM}"))
  end
end

# Allocations per room render (warm fragment cache), measured in this
# single-Ractor process with nothing else running.
class RoomRenderAllocationTest < Minitest::Test
  def test_room_render_allocations_are_bounded
    c = AppHarness::Client.new
    3.times { c.get("/rooms/486777696") }
    GC.disable
    before = GC.stat(:total_allocated_objects)
    r = c.get("/rooms/486777696")
    allocs = GC.stat(:total_allocated_objects) - before
    GC.enable
    assert_equal 200, r.status
    puts "\n  room render (40 messages, warm cache, through App#call): #{allocs} allocations, #{r.body.bytesize} bytes"
    assert_operator allocs, :<, 5_000
  end
end

# Bot replies (webhook job) append through MessageBroadcasts outside a request.
class MessageBroadcastsTest < Minitest::Test
  def test_append_renders_with_the_renderer_defaults
    db = AppHarness.db
    AppHarness.captured.clear
    room = Campfire::Room.find(db, 104393281)
    bot = Campfire::User.find(db, AppHarness::DAVID)
    m = Campfire::Message.create!(db, room, bot, body: "<p>bot says hi</p>")
    Campfire::MessageBroadcasts.append(db, room, m)
    stream, html = AppHarness.captured.find { |e| e[0] == :broadcast }[1, 2]
    assert_equal Campfire::Cable.room_messages_stream(room.type, room.id), stream
    assert html.start_with?(%(<turbo-stream action="append" target="messages_rooms_open_104393281"><template>\n  <div id="message_#{m.client_message_id}"))
    assert_includes html, "<p>bot says hi</p>"
    assert_includes html, %(data-copy-to-clipboard-content-value="http://example.org/rooms/104393281/@#{m.id}")
  end
end
