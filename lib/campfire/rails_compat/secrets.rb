# frozen_string_literal: true

require_relative "util"
require_relative "message_verifier"
require_relative "message_encryptor"
require_relative "global_id"
require_relative "csrf"
require_relative "cookies"

module Campfire
  module RailsCompat
    # Everything derived from SECRET_KEY_BASE, built once at boot:
    #
    #   SECRETS = Campfire::RailsCompat::Secrets.new(ENV.fetch("SECRET_KEY_BASE"))
    #
    # The instance is deep-frozen (Ractor.make_shareable) by the constructor, so
    # it can sit in a constant / be passed to worker Ractors. It holds only
    # frozen strings (derived keys) and immutable verifier objects; no
    # OpenSSL::Cipher/HMAC instances (the GCM cipher is cached per Ractor, see
    # MessageEncryptor).
    #
    # Key derivation = Rails.application.key_generator: PBKDF2-HMAC-SHA256,
    # 1000 iterations, 64-byte keys unless noted (~0.3 ms each, done at boot).
    class Secrets
      ITERATIONS = 1000
      SIGNED_COOKIE_SALT = "signed cookie"
      ENCRYPTED_COOKIE_SALT = "authenticated encrypted cookie"
      SIGNED_ID_SALT = "active_record/signed_id"
      SGID_SALT = "signed_global_ids"
      TURBO_SALT = "turbo/signed_stream_verifier_key"
      DEFAULT_APP_VERIFIERS = ["ActiveStorage"].freeze
      # Cookie names whose "cookie.<name>" purpose string is precomputed.
      KNOWN_COOKIES = ["session_token", "_campfire_session"].freeze

      attr_reader :cookie_verifier, :cookie_encryptor, :signed_id_verifier, :sgid_verifier, :turbo_verifier

      def initialize(secret_key_base, app_verifiers: DEFAULT_APP_VERIFIERS)
        raise ArgumentError, "SECRET_KEY_BASE is blank" if secret_key_base.nil? || secret_key_base.empty?
        @secret_key_base = secret_key_base.b.freeze

        # cookies.signed: HMAC-SHA1 (signed_cookie_digest unset -> "SHA1"),
        # NullSerializer (the jar JSON-dumps itself), strict base64.
        @cookie_verifier = MessageVerifier.new(generate_key(SIGNED_COOKIE_SALT), digest: "SHA1", encoding: :strict, serializer: :null)
        # cookies.encrypted: aes-256-gcm, 32-byte key.
        @cookie_encryptor = MessageEncryptor.new(generate_key(ENCRYPTED_COOKIE_SALT, 32), serializer: :null)

        # ActiveRecord signed ids: SHA256 / ::JSON / url-safe; falls back when
        # reading to the app default (SHA1 / json_allow_marshal / strict).
        sid_key = generate_key(SIGNED_ID_SALT)
        @signed_id_verifier = MessageVerifier.new(sid_key, digest: "SHA256", encoding: :url_safe, serializer: :json,
          fallbacks: [MessageVerifier.new(sid_key, digest: "SHA1", encoding: :strict, serializer: :json_allow_marshal)])

        # GlobalID::Verifier: SHA1, url-safe *padded*, app message serializer.
        @sgid_verifier = MessageVerifier.new(generate_key(SGID_SALT), digest: "SHA1", encoding: :url_safe_padded, serializer: :json_allow_marshal)

        # Turbo.signed_stream_verifier: SHA256, ::JSON, strict, no envelope.
        @turbo_verifier = MessageVerifier.new(generate_key(TURBO_SALT), digest: "SHA256", encoding: :strict, serializer: :json)

        @app_verifiers = app_verifiers.to_h { |name| [name.to_s, build_app_verifier(name.to_s)] }
        @cookie_purposes = KNOWN_COOKIES.to_h { |n| [n, "cookie.#{n}"] }
        Ractor.make_shareable(self)
      end

      # ActiveSupport::KeyGenerator#generate_key (uncached; PBKDF2 each call).
      def generate_key(salt, length = 64)
        OpenSSL::KDF.pbkdf2_hmac(@secret_key_base, salt: salt, iterations: ITERATIONS, length: length, hash: "SHA256")
      end

      # Rails.application.message_verifier(name): SHA1, strict base64,
      # :json_allow_marshal, key generate_key(name). Names passed to the
      # constructor (default "ActiveStorage") are prebuilt; others cost a PBKDF2.
      def app_verifier(name)
        @app_verifiers[name] || build_app_verifier(name)
      end

      # ---- signed cookies (cookies.signed[name]) ---------------------------

      # The raw (unescaped) cookie value for `cookies.signed[name] = { value:,
      # expires: }`. `value` is JSON-dumped (cookies_serializer :json).
      # For `cookies.signed.permanent` pass `expires: permanent_expiry`.
      def sign_cookie(name, value, expires: nil)
        @cookie_verifier.generate(Util.as_json_encode(value), purpose: cookie_purpose(name), expires_at: expires)
      end

      # `cookies.signed[name]` for the raw (already unescaped) cookie value:
      # the value or nil. Tries purpose "cookie.<name>", then no purpose (so
      # pre-5.2 metadata-less cookies are accepted under any name), like Rails.
      def verify_cookie(name, raw, now: Time.now)
        dumped = @cookie_verifier.decode_payload(raw) or return nil
        cookie_value_from(@cookie_verifier.serializer, dumped, name, now, true)
      end

      # ---- encrypted cookies (cookies.encrypted[name], the session) --------

      # The raw value for `cookies.encrypted[name] = { value:, expires: }`. The
      # session store writes "_campfire_session" this way with
      # expires: 20 years from now (expire_after: 20.years).
      def encrypt_cookie(name, value, expires: nil)
        @cookie_encryptor.encrypt_and_sign(Util.as_json_encode(value), purpose: cookie_purpose(name), expires_at: expires)
      end

      # `cookies.encrypted[name]`: the value (session Hash) or nil.
      def decrypt_cookie(name, raw, now: Time.now)
        plain = @cookie_encryptor.decrypt(raw) or return nil
        cookie_value_from(:null, plain, name, now, false)
      end

      # `20.years.from_now` (cookies.permanent).
      def permanent_expiry(now = Time.now) = Util.years_from(now, 20)

      # ---- signed ids (User#signed_id / find_signed) -----------------------

      # `record.signed_id(purpose:, expires_in:/expires_at:)`. model_name is the
      # *base class* name ("User"). Avatar tokens: purpose "avatar", no expiry.
      # Transfer links: purpose "transfer", expires_at: now + 4 hours.
      def signed_id(model_name, id, purpose: nil, expires_at: nil)
        @signed_id_verifier.generate(id, purpose: signed_id_purpose(model_name, purpose), expires_at: expires_at)
      end

      # find_signed's verification step: the Integer id, or nil.
      def verify_signed_id(signed_id, model_name:, purpose: nil, now: Time.now)
        v = @signed_id_verifier.read(signed_id, signed_id_purpose(model_name, purpose), Util.now_ns(now))
        case v
        when Integer then v
        when String then v.match?(/\A\s*[+-]?\d/) ? v.to_i : nil # find_by(id: "7") casts
        when Float then v.finite? ? v.to_i : nil
        end
      end

      # combine_signed_id_purposes: [base_class.name.underscore, purpose.to_s].compact_blank.join("/")
      def signed_id_purpose(model_name, purpose)
        base = RailsCompat.underscore(model_name.to_s)
        pur = purpose.to_s
        if Util.blank?(pur) then base
        elsif Util.blank?(base) then pur
        else "#{base}/#{pur}"
        end
      end

      # ---- signed global ids (ActionText attachables) ----------------------

      # `record.attachable_sgid` == to_sgid(expires_in: nil, for: "attachable");
      # GlobalID turns the leftover `expires_in: nil` into a query param, so
      # the signed data is "gid://campfire/User/1?expires_in".
      def attachable_sgid(model_name, id)
        @sgid_verifier.generate("#{GID.build(model_name, id)}?expires_in", purpose: GlobalID::ATTACHABLE_PURPOSE)
      end

      # SignedGlobalID.new(gid, for: purpose, expires_at:). `gid`: GID or URI
      # string. (`to_sgid` defaults expire in 1 month: pass expires_at.)
      def sgid(gid, purpose: GlobalID::DEFAULT_PURPOSE, expires_at: nil)
        @sgid_verifier.generate(gid.to_s, purpose: purpose, expires_at: expires_at)
      end

      # SignedGlobalID.parse(sgid, for: purpose): the GID (signature, purpose
      # and expiry checked) or nil. Also reads Rails 7.0 (Marshal string) and
      # globalid < 1.0 (self-validated metadata) sgids. Record lookup and app
      # checks are the caller's job.
      def verify_sgid(sgid, purpose: GlobalID::DEFAULT_PURPOSE, now: Time.now)
        now_ns = Util.now_ns(now)
        sgid = sgid.to_s
        data = @sgid_verifier.read(sgid, purpose, now_ns)
        if Util.invalid?(data)
          # verify_with_legacy_self_validated_metadata
          meta = @sgid_verifier.read(sgid, nil, now_ns)
          return nil if Util.invalid?(meta) || !meta.is_a?(Hash)
          if (exp = meta["expires_at"])
            exp_ns = Util.parse_iso8601_ns(exp) or return nil
            return nil if now_ns > exp_ns
          end
          return nil unless purpose.to_s == Util.purpose_to_s(meta["purpose"])
          data = meta["gid"]
        end
        GlobalID.parse(data)
      end

      # lib/rails_ext/action_text_attachables.rb (signatures ignored, only User).
      def attachable_gid_from_possibly_expired_sgid(sgid)
        GlobalID.attachable_gid_from_possibly_expired_sgid(sgid)
      end

      # ---- Turbo signed stream names --------------------------------------

      # Turbo::StreamsChannel.signed_stream_name(streamables): parts are
      # already-resolved names joined with ":" (a record is its GID#to_param,
      # e.g. `turbo_stream_from @room, :messages` ->
      # signed_stream_name(GID.build("Rooms::Open", 1).to_param, "messages")).
      def signed_stream_name(*parts)
        name = parts.length == 1 && parts[0].is_a?(String) ? parts[0] : parts.flatten.join(":")
        @turbo_verifier.generate(name)
      end

      # Turbo::StreamsChannel.verified_stream_name: the stream name or nil.
      # (A non-string payload is returned as-is, like Rails.)
      def verified_stream_name(signed)
        @turbo_verifier.verified(signed)
      end

      # ---- CSRF conveniences (stateless, see CSRF) -------------------------

      def generate_csrf_token = CSRF.generate_session_token

      # Masked global token (csrf_meta_tags / forms without per-form options).
      def mask_csrf_token(session_token, action: nil, method: nil, request_path: "/")
        CSRF.masked_token(session_token, action: action, method: method, request_path: request_path)
      end

      def valid_csrf_token?(session_token, encoded, request_path: nil, request_method: nil)
        CSRF.valid_authenticity_token?(session_token, encoded, request_path: request_path, request_method: request_method)
      end

      def inspect = "#<#{self.class.name}>"

      private

      def build_app_verifier(name)
        MessageVerifier.new(generate_key(name), digest: "SHA1", encoding: :strict, serializer: :json_allow_marshal)
      end

      def cookie_purpose(name)
        name = name.to_s
        @cookie_purposes[name] || "cookie.#{name}"
      end

      # AbstractCookieJar#[]: parse with purpose; if nil, parse without. The
      # payload was authenticated once; only the envelope check is repeated.
      def cookie_value_from(serializer, dumped, name, now, url_safe)
        now_ns = Util.now_ns(now)
        v = Metadata.deserialize_with_metadata(serializer, dumped, cookie_purpose(name), now_ns, url_safe)
        v = load_cookie_json(v)
        return v unless v.nil?
        load_cookie_json(Metadata.deserialize_with_metadata(serializer, dumped, nil, now_ns, url_safe))
      end

      # SerializedCookieJars#parse with SerializerWithFallback[:json]: Marshal
      # payloads and unparseable JSON are nil.
      def load_cookie_json(dumped)
        return nil if Util.invalid?(dumped) || !dumped.is_a?(String)
        return nil if dumped.start_with?(Util::MARSHAL_SIGNATURE)
        dumped.force_encoding(Encoding::UTF_8) unless dumped.encoding == Encoding::UTF_8
        Util.as_json_decode(dumped)
      rescue JSON::ParserError, EncodingError
        nil
      end
    end
  end
end
