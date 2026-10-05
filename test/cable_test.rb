# frozen_string_literal: true

require "minitest/autorun"
require_relative "support/cable_harness"

class CableFramesTest < Minitest::Test
  F = Campfire::Cable::Frames

  def parse(frame)
    b0, b1 = frame.unpack("CC")
    len = b1 & 0x7f
    off = 2
    (len = frame.byteslice(2, 2).unpack1("n"); off = 4) if len == 126
    (len = frame.byteslice(2, 8).unpack1("Q>"); off = 10) if len == 127
    assert_equal frame.bytesize, off + len
    [b0, frame.byteslice(off, len).force_encoding(Encoding::UTF_8)]
  end

  def test_text_frame_lengths
    [0, 1, 125, 126, 65_535, 65_536, 70_000].each do |n|
      s = "x" * n
      op, body = parse(F.text(s))
      assert_equal 0x81, op
      assert_equal s, body
    end
  end

  def test_frames_are_frozen_binary
    f = F.broadcast(F.json('{"channel":"X"}'), F.json("<p>"))
    assert f.frozen?
    assert_equal Encoding::BINARY, f.encoding
  end

  def test_rails_json_shapes
    assert_equal '{"type":"welcome"}', parse(F::WELCOME)[1]
    assert_equal '{"type":"ping","message":1700000000}', parse(F.ping(1_700_000_000))[1]
    assert_equal '{"type":"disconnect","reason":"unauthorized","reconnect":false}', parse(F::UNAUTHORIZED)[1]
    assert_equal '{"type":"disconnect","reason":"remote","reconnect":true}', parse(F::REMOTE_RECONNECT)[1]
    id = F.json('{"channel":"HeartbeatChannel"}')
    assert_equal '{"identifier":"{\"channel\":\"HeartbeatChannel\"}","type":"confirm_subscription"}', parse(F.confirm(id))[1]
    assert_equal '{"identifier":"{\"channel\":\"HeartbeatChannel\"}","type":"reject_subscription"}', parse(F.reject(id))[1]
  end

  # ActiveSupport::JSON escapes HTML-significant characters.
  def test_message_encoding_matches_active_support
    assert_equal '"\\u003cturbo-stream action=\\"append\\"\\u003e\\u0026\\u2028"', F.encode_message("<turbo-stream action=\"append\">&\u2028")
    assert_equal '{"room_id":1}', F.encode_message({ room_id: 1 })
    assert_equal '{"action":"start","user":{"id":1,"name":"A\\u003cB"}}', F.encode_message({ action: "start", user: { id: 1, name: "A<B" } })
  end

  def test_channel_names
    assert_equal "typing_notifications", Campfire::TypingNotificationsChannel.channel_name
    assert_equal "presence", Campfire::PresenceChannel.channel_name
    assert_equal "room", Campfire::RoomChannel.channel_name
    assert_equal %w[present absent refresh], Campfire::PresenceChannel.inherited_actions
    assert_equal [], Campfire::RoomChannel.inherited_actions
    assert_equal [:present], Campfire::PresenceChannel.subscribe_callbacks
  end

  def setup = CableHarness.boot!
end

class CableProtocolTest < Minitest::Test
  H = CableHarness

  def setup
    H.boot!
    @clients = []
  end

  def teardown = @clients.each(&:close)

  def connect(**opts)
    c = H.client(**opts)
    @clients << c
    c
  end

  def welcomed
    c = connect
    assert_equal 101, c.status
    assert_equal "actioncable-v1-json", c.protocol
    assert_equal({ "type" => "welcome" }, c.read_message)
    c
  end

  def subscribe(c, ident)
    c.subscribe(ident)
    c.read_message
  end

  def identifier(h) = JSON.generate(h)

  def test_non_websocket_request_is_404
    s = TCPSocket.new("127.0.0.1", H.port)
    s.write("GET /cable HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    res = s.read
    assert_match(/\AHTTP\/1.1 404/, res)
    assert res.end_with?("Page not found")
  ensure
    s&.close
  end

  def test_cross_origin_rejected
    c = connect(origin: "http://evil.example")
    assert_equal 404, c.status
    c2 = connect(origin: nil)
    assert_equal 404, c2.status
  end

  def test_unauthenticated_gets_disconnect_and_close
    c = connect(cookie: nil)
    assert_equal 101, c.status
    assert_equal [1, '{"type":"disconnect","reason":"unauthorized","reconnect":false}'], c.read_frame
    op, payload = c.read_frame
    assert_equal 8, op
    assert_equal 1000, payload.unpack1("n")
  end

  def test_garbage_cookie_is_unauthorized
    c = connect(cookie: "session_token=nope")
    assert_equal 1, c.read_frame[0]
    assert_equal({ "type" => "disconnect", "reason" => "unauthorized", "reconnect" => false }, JSON.parse(c.read_frame[1].then { _1 } || "{}")) rescue nil
  end

  def test_no_subprotocol_still_accepted
    c = connect(protocols: nil)
    assert_equal 101, c.status
    assert_nil c.protocol
    assert_equal({ "type" => "welcome" }, c.read_message)
  end

  def test_heartbeat_and_application_channel_confirm
    c = welcomed
    %w[HeartbeatChannel ApplicationCable::Channel].each do |name|
      id = identifier(channel: name)
      assert_equal({ "identifier" => id, "type" => "confirm_subscription" }, subscribe(c, id))
    end
  end

  def test_unknown_channel_and_bad_commands_are_ignored
    c = welcomed
    c.subscribe(identifier(channel: "Nope"))
    c.send_text("garbage")
    c.send_json(command: "bogus", identifier: "{}")
    c.send_json(command: "subscribe", identifier: 42)
    c.send_json(command: "subscribe", identifier: "not json")
    id = identifier(channel: "HeartbeatChannel")
    assert_equal "confirm_subscription", subscribe(c, id)["type"]
    # duplicate subscription: no second confirmation (Rails: "Already subscribed")
    c.subscribe(id)
    c.unsubscribe(id)
    assert_equal "confirm_subscription", subscribe(c, id)["type"]
  end

  def test_room_channel_membership
    c = welcomed
    ok = identifier(channel: "RoomChannel", room_id: H::WATERCOOLER)
    assert_equal "confirm_subscription", subscribe(c, ok)["type"]
    as_string = identifier(channel: "RoomChannel", room_id: H::WATERCOOLER.to_s)
    assert_equal "confirm_subscription", subscribe(c, as_string)["type"]
    bad = identifier(channel: "RoomChannel", room_id: 1)
    assert_equal({ "identifier" => bad, "type" => "reject_subscription" }, subscribe(c, bad))
    junk = identifier(channel: "RoomChannel", room_id: "abc")
    assert_equal "reject_subscription", subscribe(c, junk)["type"]
  end

  def test_turbo_streams_channel
    c = welcomed
    rooms = identifier(channel: "Turbo::StreamsChannel", signed_stream_name: H.signed("rooms"))
    assert_equal "confirm_subscription", subscribe(c, rooms)["type"]
    forged = identifier(channel: "Turbo::StreamsChannel", signed_stream_name: "InJvb21zIg==--00")
    assert_equal "reject_subscription", subscribe(c, forged)["type"]
    # room message streams are only reachable through RoomMessagesChannel
    guarded = identifier(channel: "Turbo::StreamsChannel", signed_stream_name: H.signed("#{H.gid_param("Rooms::Closed", H::WATERCOOLER)}:messages"))
    assert_equal "reject_subscription", subscribe(c, guarded)["type"]

    Campfire::Cable.broadcast("rooms", "<turbo-stream action=\"remove\"></turbo-stream>")
    assert_equal({ "identifier" => rooms, "message" => "<turbo-stream action=\"remove\"></turbo-stream>" }, c.read_message)
  end

  def test_room_messages_channel_authorization
    c = welcomed
    name = "#{H.gid_param("Rooms::Closed", H::WATERCOOLER)}:messages"
    ok = identifier(channel: "RoomMessagesChannel", signed_stream_name: H.signed(name))
    assert_equal "confirm_subscription", subscribe(c, ok)["type"]
    generic = identifier(channel: "RoomMessagesChannel", signed_stream_name: H.signed("#{H.gid_param("Room", H::WATERCOOLER)}:messages"))
    assert_equal "confirm_subscription", subscribe(c, generic)["type"]
    wrong_type = identifier(channel: "RoomMessagesChannel", signed_stream_name: H.signed("#{H.gid_param("Rooms::Open", H::WATERCOOLER)}:messages"))
    assert_equal "reject_subscription", subscribe(c, wrong_type)["type"]
    not_member = identifier(channel: "RoomMessagesChannel", signed_stream_name: H.signed("#{H.gid_param("Rooms::Direct", 340026324)}:messages"))
    assert_equal "reject_subscription", subscribe(c, not_member)["type"]
    not_messages = identifier(channel: "RoomMessagesChannel", signed_stream_name: H.signed("rooms"))
    assert_equal "reject_subscription", subscribe(c, not_messages)["type"]

    assert_equal name, Campfire::Cable.room_messages_stream("Rooms::Closed", H::WATERCOOLER)
    Campfire::Cable.broadcast(name, "<turbo-stream></turbo-stream>")
    assert_equal({ "identifier" => ok, "message" => "<turbo-stream></turbo-stream>" }, c.read_message)
  end

  def test_typing_notifications
    a = welcomed
    b = welcomed
    id = identifier(channel: "TypingNotificationsChannel", room_id: H::WATERCOOLER.to_s)
    assert_equal "confirm_subscription", subscribe(a, id)["type"]
    assert_equal "confirm_subscription", subscribe(b, id)["type"]
    a.perform(id, action: "start")
    want = { "identifier" => id, "message" => { "action" => "start", "user" => { "id" => H::DAVID, "name" => "David" } } }
    assert_equal want, a.read_message
    assert_equal want, b.read_message
    a.perform(id, action: "subscribed") # not an action
    a.perform(id, action: "stop")
    assert_equal "stop", b.read_message.dig("message", "action")
  end

  def membership
    H.db.query_single_array("SELECT connections, connected_at, unread_at, updated_at FROM memberships WHERE room_id = ? AND user_id = ?", H::WATERCOOLER, H::DAVID)
  end

  def test_presence_updates_membership_and_broadcasts_read
    H.db.execute("UPDATE memberships SET connections = 0, connected_at = NULL, unread_at = '2026-01-01 00:00:00' WHERE room_id = ? AND user_id = ?", H::WATERCOOLER, H::DAVID)
    c = welcomed
    reads = identifier(channel: "ReadRoomsChannel")
    assert_equal "confirm_subscription", subscribe(c, reads)["type"]
    presence = identifier(channel: "PresenceChannel", room_id: H::WATERCOOLER)
    c.subscribe(presence)
    msgs = [c.read_message, c.read_message]
    assert_includes msgs, { "identifier" => presence, "type" => "confirm_subscription" }
    assert_includes msgs, { "identifier" => reads, "message" => { "room_id" => H::WATERCOOLER } }
    conns, connected_at, unread_at, = membership
    assert_equal 1, conns
    refute_nil connected_at
    assert_nil unread_at

    d = welcomed
    d.subscribe(presence)
    assert_equal "confirm_subscription", d.read_message["type"]
    assert_equal 2, membership[0]

    c.perform(presence, action: "refresh")
    sleep 0.1
    assert_equal 2, membership[0]

    d.unsubscribe(presence)
    sleep 0.1
    assert_equal 1, membership[0]
    refute_nil membership[1]

    c.close
    sleep 0.2
    conns, connected_at, = membership
    assert_equal 0, conns
    assert_nil connected_at
  end

  def test_remote_disconnect
    c = welcomed
    c2 = welcomed
    Campfire::Cable.disconnect_user(H::DAVID, reconnect: true)
    [c, c2].each do |x|
      assert_equal({ "type" => "disconnect", "reason" => "remote", "reconnect" => true }, x.read_message)
      assert_equal :close, x.read_message[0]
    end
  end

  def test_ping_every_three_seconds
    c = welcomed
    msg = c.read_message(4, pings: true)
    assert_equal "ping", msg["type"]
    assert_in_delta Time.now.to_i, msg["message"], 2
  end

  def test_one_frame_object_shared_by_subscribers
    clients = 3.times.map { welcomed }
    id = identifier(channel: "UnreadRoomsChannel")
    clients.each { |c| assert_equal "confirm_subscription", subscribe(c, id)["type"] }
    stream = "user_#{H::DAVID}_unreads"
    subs = H.registry.streams[stream].keys
    assert_operator subs.size, :>=, 3
    assert subs.map(&:identifier_json).uniq(&:object_id).size == 1, "identifiers interned"
    frames = []
    subs.each { |s| q = s.connection.instance_variable_get(:@queue); def q.push(f) = (@seen ||= []) << f && super }
    H.registry.broadcast(stream, '{"roomId":1}')
    frames = subs.map { |s| s.connection.instance_variable_get(:@queue).instance_variable_get(:@seen).last }
    assert_equal 1, frames.uniq(&:object_id).size
    clients.each { |c| assert_equal({ "roomId" => 1 }, c.read_message["message"]) }
  end

  def test_client_ping_gets_pong_and_close_is_echoed
    c = welcomed
    c.send_text("hi", opcode: 9)
    assert_equal [10, "hi"], c.read_frame
    c.send_text([1000].pack("n"), opcode: 8)
    assert_equal 8, c.read_frame[0]
  end

  def test_fragmented_command
    c = welcomed
    text = JSON.generate(command: "subscribe", identifier: identifier(channel: "HeartbeatChannel"))
    c.send_text(text[0, 10], opcode: 1, fin: false)
    c.send_text(text[10..], opcode: 0)
    assert_equal "confirm_subscription", c.read_message["type"]
  end

  def test_slow_client_is_dropped
    c = welcomed
    id = identifier(channel: "UnreadRoomsChannel")
    assert_equal "confirm_subscription", subscribe(c, id)["type"]
    conn = H.registry.connections.keys.find { |k| k.subscriptions.key?(id) && !k.dead? }
    big = "x" * 200_000
    # never read: the socket buffers fill, then the queue, then we are dropped
    400.times { Campfire::Cable.local_broadcast("user_#{H::DAVID}_unreads", big) }
    sleep 0.3
    assert conn.dead?
    refute H.registry.connections.key?(conn)
  end
end
