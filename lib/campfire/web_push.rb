# frozen_string_literal: true

require "openssl"
require "uri"
require "socket"
require "async/http/client"
require "async/http/endpoint"

module Campfire
  # Outgoing HTTP from job Ractors (Web Push, bot webhooks) on async-http.
  #
  # Resolv's default resolver isn't shareable, so names are resolved with
  # getaddrinfo on a plain Thread (Thread#value yields to the fiber scheduler),
  # and the connection is pinned to the chosen address; TLS still verifies the
  # URL's host name.
  module Outbound
    Response = Data.define(:status, :content_type, :body)
    class TooLarge < StandardError; end

    module_function

    def resolve(host, port)
      Thread.new { Addrinfo.getaddrinfo(host, port, nil, :STREAM).map(&:ip_address) }.value
    end

    # POST `body` to `url`, connecting to `ip`. `timeout` bounds connecting
    # and each socket read/write (Net::HTTP's open/read timeouts).
    def post(url, body, headers, ip:, timeout:, limit: nil)
      Sync { post!(url, body, headers, ip, timeout, limit) }
    end

    def post!(url, body, headers, ip, timeout, limit)
      request("POST", url, headers, ip: ip, timeout: timeout, body: body) do |response|
        Response.new(response.status, response.headers["content-type"]&.to_s, read_body(response, limit))
      end
    end

    # One request to `url` over a connection pinned to `ip`; yields the response
    # (headers read, body unread) and closes it after the block. Call inside a
    # reactor (Sync).
    def request(verb, url, headers, ip:, timeout:, body: nil, authority: nil)
      uri = url.is_a?(URI) ? url : URI.parse(url)
      endpoint = Async::HTTP::Endpoint.new(uri, tcp_endpoint(ip, uri.port, timeout), timeout: timeout)
      client = Async::HTTP::Client.new(endpoint, retries: 0)
      response = nil
      begin
        h = Protocol::HTTP::Headers.new
        headers.each { |k, v| h.add(k, v) }
        request = Protocol::HTTP::Request.new(endpoint.scheme, authority || endpoint.authority, verb, uri.request_uri, nil, h,
          body && Protocol::HTTP::Body::Buffered.wrap(body))
        response = client.call(request)
        yield response
      ensure
        response&.close rescue nil
        client.close
      end
    end

    # The pinned connection (tests point it elsewhere).
    def tcp_endpoint(ip, port, timeout) = IO::Endpoint.tcp(ip, port, timeout: timeout)

    def read_body(response, limit)
      body = response.body or return "".b
      buf = String.new(encoding: Encoding::BINARY)
      while (chunk = body.read)
        buf << chunk
        if limit && buf.bytesize > limit
          body.close
          raise TooLarge, "response exceeds #{limit} bytes"
        end
      end
      buf
    ensure
      response.close rescue nil
    end
  end

  # Web Push (RFC 8291 aes128gcm + RFC 8292 VAPID), as the web-push gem and
  # lib/web_push/notification.rb send it, with nothing but stdlib openssl.
  module WebPush
    SUBJECT = "mailto:support@37signals.com"
    TTL = 2_419_200 # the gem's default, four weeks
    TIMEOUT = 30
    JWT_EXPIRATION = 12 * 60 * 60
    MAX_RECORD = 4096
    ICON_PATH = "/account/logo"
    JWT_HEADER = "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9" # {"typ":"JWT","alg":"ES256"}
    # DER prefixes for a P-256 SubjectPublicKeyInfo and ECPrivateKey.
    SPKI_PREFIX = ["3059301306072a8648ce3d020106082a8648ce3d030107034200"].pack("H*").freeze
    CURVE = "prime256v1"
    GEM_PADDING = "\x02\x00".b.freeze

    class Error < StandardError; end
    class ExpiredSubscription < Error; end # 410: the subscription is gone
    class ResponseError < Error
      attr_reader :status
      def initialize(status) = super("push service responded #{@status = status}")
    end

    module_function

    def b64(bytes) = [bytes].pack("m0").tr("+/", "-_").delete("=")

    # Base64.urlsafe_decode64 (padding optional).
    def unb64(str)
      s = str.to_s.tr("-_", "+/").delete("=")
      s += "=" * (-s.length % 4)
      s.unpack1("m0")
    end

    def public_key(raw)
      # The gem's EC::Point.new raises this OpenSSLError (so WebPush::Pool
      # destroys the subscription) for a key that isn't an uncompressed point.
      raise OpenSSL::PKey::EC::Point::Error, "invalid public key" unless raw.bytesize == 65 && raw.getbyte(0) == 4
      OpenSSL::PKey.read(SPKI_PREFIX + raw)
    end

    def private_key(d)
      raise Error, "bad P-256 private key" unless d.bytesize == 32
      group = OpenSSL::PKey::EC::Group.new(CURVE)
      pub = group.generator.mul(OpenSSL::BN.new(d, 2)).to_octet_string(:uncompressed)
      der = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::Integer(1),
        OpenSSL::ASN1::OctetString(d),
        OpenSSL::ASN1::ObjectId.new(CURVE, 0, :EXPLICIT, :CONTEXT_SPECIFIC),
        OpenSSL::ASN1::BitString.new(pub, 1, :EXPLICIT, :CONTEXT_SPECIFIC)
      ]).to_der
      OpenSSL::PKey::EC.new(der)
    end

    def raw_public(key) = key.public_key.to_octet_string(:uncompressed)

    def hkdf(ikm, salt, info, length) = OpenSSL::KDF.hkdf(ikm, salt: salt, info: info, length: length, hash: "SHA256")

    # WebPush::Encryption.encrypt: salt(16) | rs(4) | idlen(1) | server key(65) | ciphertext.
    # The gem pads with "\x02\x00" and declares rs = ciphertext size; `padding`
    # and `rs` exist for the RFC 8291 vector.
    def encrypt(message, p256dh, auth, server_key: OpenSSL::PKey::EC.generate(CURVE), salt: OpenSSL::Random.random_bytes(16),
      padding: GEM_PADDING, rs: nil)
      client_raw = unb64(p256dh)
      client = public_key(client_raw)
      server_raw = raw_public(server_key)
      shared = server_key.derive(client)
      prk = hkdf(shared, unb64(auth), "WebPush: info\0".b + client_raw + server_raw, 32)
      cek = hkdf(prk, salt, "Content-Encoding: aes128gcm\0", 16)
      nonce = hkdf(prk, salt, "Content-Encoding: nonce\0", 12)
      cipher = OpenSSL::Cipher.new("aes-128-gcm").encrypt
      cipher.key = cek
      cipher.iv = nonce
      ciphertext = cipher.update(message.b) + cipher.update(padding) + cipher.final + cipher.auth_tag
      raise ArgumentError, "encrypted payload is too big" if ciphertext.bytesize > MAX_RECORD
      salt.b + [rs || ciphertext.bytesize].pack("N") + [server_raw.bytesize].pack("C") + server_raw + ciphertext
    end

    # The receiving side (tests): returns the plaintext with the padding removed.
    def decrypt(body, receiver_key, auth)
      body = body.b
      salt = body.byteslice(0, 16)
      idlen = body.getbyte(20)
      server_raw = body.byteslice(21, idlen)
      ciphertext = body.byteslice(21 + idlen..)
      receiver_raw = raw_public(receiver_key)
      shared = receiver_key.derive(public_key(server_raw))
      prk = hkdf(shared, auth, "WebPush: info\0".b + receiver_raw + server_raw, 32)
      cipher = OpenSSL::Cipher.new("aes-128-gcm").decrypt
      cipher.key = hkdf(prk, salt, "Content-Encoding: aes128gcm\0", 16)
      cipher.iv = hkdf(prk, salt, "Content-Encoding: nonce\0", 12)
      cipher.auth_tag = ciphertext.byteslice(-16, 16)
      plain = cipher.update(ciphertext.byteslice(0, ciphertext.bytesize - 16)) + cipher.final
      plain.sub(/\x02\x00*\z/n, "")
    end

    # VAPID keys from VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY (URL-safe Base64 of
    # the raw 65-byte point and 32-byte scalar). Parsed once per Ractor.
    Vapid = Data.define(:key, :public_raw, :subject)

    def vapid(config = Campfire.config)
      Ractor[:web_push_vapid] ||= begin
        pub, priv = config.vapid_public_key, config.vapid_private_key
        raise Error, "VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY aren't set" if pub.to_s.empty? || priv.to_s.empty?
        key = private_key(unb64(priv))
        raise Error, "VAPID_PUBLIC_KEY isn't the public key of VAPID_PRIVATE_KEY" unless raw_public(key) == unb64(pub)
        Vapid.new(key, raw_public(key), SUBJECT)
      end
    end

    def jwt_payload(audience, exp, subject) = JSON.generate({ aud: audience, exp: exp, sub: subject })

    # WebPush::Request#build_vapid_header: "vapid t=<ES256 JWT>,k=<public key>".
    def authorization(endpoint, vapid, now: Time.now.to_i)
      uri = endpoint.is_a?(URI) ? endpoint : URI.parse(endpoint)
      signing_input = "#{JWT_HEADER}.#{b64(jwt_payload("#{uri.scheme}://#{uri.host}", now + JWT_EXPIRATION, vapid.subject))}"
      der = vapid.key.sign("SHA256", signing_input)
      asn = OpenSSL::ASN1.decode(der)
      sig = asn.value.map { |i| i.value.to_s(2).rjust(32, "\0") }.join
      "vapid t=#{signing_input}.#{b64(sig)},k=#{b64(vapid.public_raw)}"
    end

    # WebPush::Notification#encoded_message (JSON.generate: no HTML escaping).
    def encoded_message(title, body, path, badge)
      JSON.generate({ title: title, options: { body: body, icon: ICON_PATH, data: { path: path, badge: badge } } })
    end

    def headers(body, authorization)
      [
        ["content-type", "application/octet-stream"],
        ["ttl", TTL.to_s],
        ["urgency", "high"],
        ["content-encoding", "aes128gcm"],
        ["content-length", body.bytesize.to_s],
        ["authorization", authorization]
      ]
    end

    # WebPush.payload_send pinned to `ip` (Push::Subscription#resolved_endpoint_ip).
    # Raises ExpiredSubscription on 410 and ResponseError on any other non-2xx,
    # as WebPush::Request#verify_response does.
    def deliver(endpoint, ip, p256dh, auth, message, vapid: self.vapid, now: Time.now.to_i)
      uri = URI.parse(endpoint)
      body = encrypt(message, p256dh, auth)
      res = Outbound.post(uri, body, headers(body, authorization(uri, vapid, now: now)), ip: ip, timeout: TIMEOUT, limit: 1 << 20)
      raise ExpiredSubscription, "push subscription expired" if res.status == 410
      raise ResponseError.new(res.status) unless (200..299).cover?(res.status)
      res.status
    end

    # Push::Subscription#resolved_endpoint_ip: a public address of a permitted
    # https:443 endpoint, or nil.
    def resolve_endpoint_ip(endpoint)
      uri = (URI.parse(endpoint) rescue nil) or return nil
      return nil unless uri.scheme == "https" && uri.port == 443
      host = uri.host&.downcase
      return nil if host.nil? || host.empty?
      return nil unless PushSubscription::PERMITTED_ENDPOINT_HOSTS.any? { |p| host == p || host.end_with?(".#{p}") }
      ips = Outbound.resolve(host, 443)
      ips.find { |ip| public_ip?(ip) }
    rescue SocketError
      nil
    end

    def public_ip?(ip)
      addr = IPAddr.new(ip) rescue (return false)
      addr = addr.native if addr.ipv6? && addr.ipv4_mapped?
      PushSubscription::BLOCKED.none? { |b| b.family == addr.family && b.include?(addr) }
    end
  end
end
