# frozen_string_literal: true

# Web Push (aes128gcm + VAPID) against the reference vectors: the web-push gem's
# output captured from the Rails app (ref-rust testdata) and RFC 8291 §5.
require "minitest/autorun"
require_relative "../lib/campfire"
require "ipaddr"
require_relative "../app/models/push_subscription"
require_relative "../lib/campfire/web_push"
require_relative "support/fake_http"

class WebPushTest < Minitest::Test
  W = Campfire::WebPush
  V = JSON.parse(File.read("/home/tobi/src/once/ref-rust/crates/campfire/src/integrations/testdata/web_push_expected.json"))
  VAPID_PUBLIC = "BEYXTBB5_jNhNzXDmx5KEU55Vbbd-u--Lk9rM5OFQvUkPIBwZJ9QzAq0zdEzFw6yTV8cTriz_qYBVicY02_VxTQ="
  VAPID_PRIVATE = "qfXLHghuG1rSHZUVo9SscNRI-0EIHRbIrfeGCqbAwak="
  Cfg = Struct.new(:vapid_public_key, :vapid_private_key)

  def receiver = W.private_key(W.unb64(V["receiver_private_key"]))
  def vapid = W::Vapid.new(W.private_key(W.unb64(VAPID_PRIVATE)), W.unb64(VAPID_PUBLIC), W::SUBJECT)

  def test_receiver_key_matches_p256dh
    assert_equal V["p256dh"].delete("="), W.b64(W.raw_public(receiver))
  end

  def test_decrypts_reference_ciphertext
    body = W.unb64(V["ciphertext"])
    assert_equal 270, body.bytesize
    assert_equal 184, body.byteslice(16, 4).unpack1("N")
    assert_equal V["message"], W.decrypt(body, receiver, W.unb64(V["auth"])).force_encoding("UTF-8")
  end

  def test_encrypt_round_trips_with_gem_layout
    body = W.encrypt(V["message"], V["p256dh"], V["auth"])
    assert_equal V["headers"].to_h["Content-Length"].to_i, body.bytesize
    assert_equal 184, body.byteslice(16, 4).unpack1("N")
    assert_equal 65, body.getbyte(20)
    assert_equal V["message"], W.decrypt(body, receiver, W.unb64(V["auth"])).force_encoding("UTF-8")
  end

  def test_rfc8291_vector
    server = W.private_key(W.unb64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
    body = W.encrypt(W.unb64("V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24"),
      "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4", "BTBZMqHH6r4Tts7J_aSIgg",
      server_key: server, salt: W.unb64("DGv6ra1nlYgDCS1FRnbzlw"), padding: "\x02".b, rs: 4096)
    assert_equal "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
      W.b64(body)
  end

  def test_payload_too_big
    assert_raises(ArgumentError) { W.encrypt("x" * 4081, V["p256dh"], V["auth"]) }
    W.encrypt("x" * 4078, V["p256dh"], V["auth"]) # 4078 + 2 + 16 = 4096
  end

  def test_vapid_header_like_the_gem
    auth = W.authorization("https://fcm.googleapis.com/fcm/send/abc", vapid, now: V["now"])
    t, k = auth.delete_prefix("vapid t=").split(",k=")
    header, payload, sig = t.split(".")
    assert_equal V["jwt_header_segment"], header
    assert_equal V["jwt_payload_segment"], payload
    assert_equal V["authorization_k"], k
    r, s = W.unb64(sig).unpack("a32a32")
    der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(OpenSSL::BN.new(r, 2)), OpenSSL::ASN1::Integer(OpenSSL::BN.new(s, 2))]).to_der
    assert W.public_key(W.unb64(k)).verify("SHA256", der, "#{header}.#{payload}")
  end

  def test_vapid_config_checks_keys
    assert_equal W.unb64(VAPID_PUBLIC), W.vapid(Cfg.new(VAPID_PUBLIC, VAPID_PRIVATE)).public_raw
    Ractor[:web_push_vapid] = nil
    assert_raises(W::Error) { W.vapid(Cfg.new(V["p256dh"], VAPID_PRIVATE)) }
    Ractor[:web_push_vapid] = nil
    assert_raises(W::Error) { W.vapid(Cfg.new(nil, nil)) }
  ensure
    Ractor[:web_push_vapid] = nil
  end

  def test_encoded_message_like_json_generate
    msg = W.encoded_message("Designers <&> \"quotes\" é 😀", "Kevin: line\nbreak\ttab   \u001f / \\ ", "/rooms/1", 3)
    assert_equal V["message"], msg
  end

  def test_endpoint_resolution_guard
    assert_nil W.resolve_endpoint_ip("http://fcm.googleapis.com/x")
    assert_nil W.resolve_endpoint_ip("https://fcm.googleapis.com:8443/x")
    assert_nil W.resolve_endpoint_ip("https://evil.example.com/x")
    assert_nil W.resolve_endpoint_ip("https://fcm.googleapis.com.evil.com/x")
    refute W.public_ip?("127.0.0.1")
    refute W.public_ip?("::ffff:10.0.0.1")
    assert W.public_ip?("142.250.185.206")
  end

  def test_deliver_posts_gem_headers_and_handles_410
    server = FakeHTTP.new { |req| req.path.end_with?("gone") ? [410, {}, ""] : [201, {}, ""] }
    url = "http://127.0.0.1:#{server.port}/fcm/send/abc"
    status = Sync { W.deliver(url, "127.0.0.1", V["p256dh"], V["auth"], V["message"], vapid: vapid, now: V["now"]) }
    assert_equal 201, status
    req = server.requests.last
    assert_equal "POST", req.method
    assert_equal "application/octet-stream", req.headers["content-type"]
    assert_equal "2419200", req.headers["ttl"]
    assert_equal "high", req.headers["urgency"]
    assert_equal "aes128gcm", req.headers["content-encoding"]
    assert_equal req.body.bytesize.to_s, req.headers["content-length"]
    assert_match(/\Avapid t=#{V["jwt_header_segment"]}\.[^.]+\.[^.]+,k=#{V["authorization_k"]}\z/, req.headers["authorization"])
    assert_equal V["message"], W.decrypt(req.body, receiver, W.unb64(V["auth"])).force_encoding("UTF-8")
    assert_raises(W::ExpiredSubscription) do
      Sync { W.deliver(url + "gone", "127.0.0.1", V["p256dh"], V["auth"], "x", vapid: vapid) }
    end
  ensure
    server&.close
  end

  def test_works_inside_a_ractor
    r = Ractor.new(V["p256dh"], V["auth"], V["receiver_private_key"]) do |p256dh, auth, priv|
      w = Campfire::WebPush
      body = w.encrypt("hello", p256dh, auth)
      w.decrypt(body, w.private_key(w.unb64(priv)), w.unb64(auth))
    end
    assert_equal "hello", r.value
  end
end
