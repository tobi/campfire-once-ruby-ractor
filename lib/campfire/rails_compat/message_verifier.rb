# frozen_string_literal: true

require_relative "util"

module Campfire
  module RailsCompat
    # ActiveSupport::Messages::Metadata: how a value plus purpose/expiry is
    # packed into the bytes that get signed or encrypted.
    #
    # Two envelopes exist:
    # * serializer is JSON-ish (`:json`, `:json_fallback`, `:json_allow_marshal`):
    #   `{"_rails":{"data":<value>,"exp":"...","pur":"..."}}` (keys only when set).
    # * the cookie jars' NullSerializer (`:null`) uses the legacy dual-serialized
    #   envelope `{"_rails":{"message":"<b64 of dumped>","exp":..,"pur":..}}`
    #   which always carries exp and pur (null when unset).
    #
    # Serializers:
    #   :null               ActiveSupport::MessageEncryptor::NullSerializer (strings as-is)
    #   :json               ::JSON (JSON.dump / JSON.load) — Turbo, signed ids
    #   :json_fallback      SerializerWithFallback[:json] (ActiveSupport::JSON, no Marshal)
    #   :json_allow_marshal SerializerWithFallback[:json_allow_marshal] (app default)
    module Metadata
      LEGACY_PREFIX = '{"_rails":{"message":'

      module_function

      def dump(serializer, value)
        case serializer
        when :null then value.is_a?(String) ? value : value.to_s
        when :json then Util.json_dump(value)
        else Util.as_json_encode(value)
        end
      end

      # Returns the value, or Util::INVALID_SERIALIZATION.
      def load(serializer, bytes)
        case serializer
        when :null
          bytes
        when :json
          Util.json_load(bytes)
        else
          if bytes.start_with?(Util::MARSHAL_SIGNATURE)
            return Util::INVALID_SERIALIZATION unless serializer == :json_allow_marshal
            Util.marshal_load_string(bytes) || Util::INVALID_SERIALIZATION
          else
            Util.as_json_decode(bytes)
          end
        end
      rescue JSON::ParserError, EncodingError, TypeError, ArgumentError
        Util::INVALID_SERIALIZATION
      end

      def serialize_with_metadata(serializer, value, purpose, expires_at)
        exp = expires_at && (expires_at.is_a?(String) ? expires_at : Util.iso8601_ms(expires_at))
        if purpose.nil? && exp.nil?
          dump(serializer, value)
        elsif serializer == :null
          envelope = { "_rails" => { "message" => Util.strict_encode64(dump(serializer, value)), "exp" => exp, "pur" => purpose } }
          Util.as_json_encode(envelope)
        else
          inner = { "data" => value }
          inner["exp"] = exp if exp
          inner["pur"] = purpose.to_s if purpose
          dump(serializer, { "_rails" => inner })
        end
      end

      # `generate` with data the caller already dumped (controls key order /
      # escaping). Only for JSON-ish serializers.
      def serialize_dumped_with_metadata(serializer, data_json, purpose, expires_at)
        exp = expires_at && (expires_at.is_a?(String) ? expires_at : Util.iso8601_ms(expires_at))
        return data_json.dup if purpose.nil? && exp.nil?
        out = +'{"_rails":{"data":'
        out << data_json
        out << ',"exp":' << dump(serializer, exp) if exp
        out << ',"pur":' << dump(serializer, purpose.to_s) if purpose
        out << "}}"
      end

      # deserialize_with_metadata. `legacy_url_safe`: whether the base64 inside a
      # legacy envelope may use either alphabet (verifier) or must be strict
      # (encryptor). Returns the value or a Util::INVALID_* sentinel.
      def deserialize_with_metadata(serializer, bytes, purpose, now_ns, legacy_url_safe)
        if bytes.start_with?(LEGACY_PREFIX)
          envelope = begin
            Util.as_json_decode(bytes)
          rescue JSON::ParserError, EncodingError
            return Util::INVALID_FORMAT
          end
          rails = envelope["_rails"]
          return Util::INVALID_FORMAT unless rails.is_a?(Hash)
          r = check_envelope(rails, purpose, now_ns)
          return r if r
          message = rails["message"]
          return Util::INVALID_FORMAT unless message.is_a?(String)
          dumped = legacy_url_safe ? Util.urlsafe_decode64(message) : Util.strict_decode64(message)
          return Util::INVALID_FORMAT unless dumped
          load(serializer, dumped)
        else
          value = load(serializer, bytes)
          return value if value == Util::INVALID_SERIALIZATION
          if value.is_a?(Hash) && value.key?("_rails")
            rails = value["_rails"]
            return Util::INVALID_FORMAT unless rails.is_a?(Hash) # Rails raises here
            r = check_envelope(rails, purpose, now_ns)
            r || rails["data"]
          elsif purpose.nil?
            value
          else
            Util::INVALID_CONTENT
          end
        end
      end

      # extract_from_metadata_envelope: nil when OK, else a sentinel.
      def check_envelope(rails, purpose, now_ns)
        if (exp = rails["exp"])
          exp_ns = Util.parse_iso8601_ns(exp)
          return Util::INVALID_FORMAT unless exp_ns # Time.iso8601 raises in Rails
          return Util::INVALID_CONTENT if now_ns >= exp_ns
        end
        pur = Util.purpose_to_s(rails["pur"])
        return Util::INVALID_CONTENT unless pur == (purpose || "")
        nil
      end
    end

    # ActiveSupport::MessageVerifier:
    #   "<base64 payload>--<hex HMAC of the base64 payload>"
    #
    # Instances are immutable (frozen on construction) and hold only frozen
    # strings/symbols, so they are Ractor-shareable.
    #
    # encoding: :strict (default), :url_safe (unpadded, `url_safe: true`) or
    # :url_safe_padded (GlobalID::Verifier). Reading is always lenient (either
    # alphabet, optional padding), as Rails' decode-with-fallback is.
    class MessageVerifier

      attr_reader :digest, :encoding, :serializer

      def initialize(secret, digest: "SHA1", encoding: :strict, serializer: :json_allow_marshal, fallbacks: [])
        @secret = secret.b.freeze
        @digest = digest.to_s.upcase.freeze
        @hex_length = OpenSSL::Digest.new(@digest).digest_length * 2
        @encoding = encoding
        @serializer = serializer
        @fallbacks = fallbacks.freeze
        Ractor.make_shareable(self)
      end

      # `generate(value, purpose:, expires_at:)`. expires_at: Time or nil.
      def generate(value, purpose: nil, expires_at: nil)
        sign_encoded(encode(Metadata.serialize_with_metadata(@serializer, value, purpose, expires_at)))
      end

      # `generate` for data already dumped as JSON (controls key order).
      def generate_raw(data_json, purpose: nil, expires_at: nil)
        sign_encoded(encode(Metadata.serialize_dumped_with_metadata(@serializer, data_json, purpose, expires_at)))
      end

      # `verified`: the value or nil (for any error: tampered, expired, wrong
      # purpose, undecodable). Note that a validly signed `null` is also nil.
      def verified(message, purpose: nil, now: Time.now)
        v = read(message, purpose, Util.now_ns(now))
        Util.invalid?(v) ? nil : v
      end
      alias verify verified

      # Like `verified`, but returns `[ok, value]` so a signed nil/false is
      # distinguishable from failure.
      def verified_pair(message, purpose: nil, now: Time.now)
        v = read(message, purpose, Util.now_ns(now))
        Util.invalid?(v) ? [false, nil] : [true, v]
      end

      # `valid_message?`: signature only.
      def valid_message?(message)
        !extract_encoded(message).nil?
      end

      # Internal: value or Util::INVALID_* sentinel, trying fallbacks (rotations)
      # on format/serialization errors only, as ActiveSupport::Messages::Rotator.
      def read(message, purpose, now_ns)
        v = read_message(message, purpose, now_ns)
        if (v == Util::INVALID_FORMAT || v == Util::INVALID_SERIALIZATION) && !@fallbacks.empty?
          @fallbacks.each do |f|
            r = f.read_message(message, purpose, now_ns)
            next if r == Util::INVALID_FORMAT || r == Util::INVALID_SERIALIZATION
            return r
          end
        end
        v
      end

      def read_message(message, purpose, now_ns)
        decoded = decode_payload(message)
        return Util::INVALID_FORMAT unless decoded
        Metadata.deserialize_with_metadata(@serializer, decoded, purpose, now_ns, true)
      end

      # Signature check + base64 decode; the raw serialized bytes or nil.
      def decode_payload(message)
        encoded = extract_encoded(message) or return nil
        Util.urlsafe_decode64(encoded)
      end

      # extract_encoded: digest is the last hex_length chars, preceded by "--".
      def extract_encoded(signed)
        return nil unless signed.is_a?(String) && signed.ascii_only?
        idx = signed.bytesize - @hex_length - 2
        return nil if idx < 0 || signed.getbyte(idx) != 45 || signed.getbyte(idx + 1) != 45
        encoded = signed.byteslice(0, idx)
        digest = signed.byteslice(idx + 2, @hex_length)
        return nil if Util.blank?(encoded) || Util.blank?(digest)
        OpenSSL.fixed_length_secure_compare(digest, OpenSSL::HMAC.hexdigest(@digest, @secret, encoded)) ? encoded : nil
      end

      def inspect = "#<#{self.class.name} #{@digest} #{@encoding} #{@serializer}>"

      private

      def encode(bin)
        case @encoding
        when :url_safe then Util.urlsafe_encode64_unpadded(bin)
        when :url_safe_padded then Util.urlsafe_encode64_padded(bin)
        else Util.strict_encode64(bin)
        end
      end

      def sign_encoded(encoded)
        digest = OpenSSL::HMAC.hexdigest(@digest, @secret, encoded)
        encoded << "--" << digest
      end
    end
  end
end
