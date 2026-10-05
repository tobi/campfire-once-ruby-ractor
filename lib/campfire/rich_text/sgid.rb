# frozen_string_literal: true

require "json"
require "openssl"
require "time"

module Campfire
  module RichText
    # Global ID helpers for attachment sgids.
    module SGID
      MARSHAL_GID = %r{gid://campfire/[^/]+/\d+}n

      module_function

      # Base64.strict_decode64, falling back to urlsafe_decode64 (as Rails does).
      def decode64(s)
        s.unpack1("m0")
      rescue ArgumentError
        s = s.end_with?("=") || (s.length % 4).zero? ? s.tr("-_", "+/") : s.ljust((s.length + 3) & ~3, "=").tr("-_", "+/")
        s.unpack1("m0")
      end

      # The User id named by "gid://<app>/User/<id>[?params]" (or its urlsafe
      # base64 form, as GlobalID.parse accepts), else nil.
      def user_id(gid)
        return unless gid.is_a?(String)
        unless gid.start_with?("gid://")
          gid = begin
            decode64(gid).force_encoding(Encoding::UTF_8)
          rescue ArgumentError
            return
          end
        end
        parts = gid.split("?", 2).first.split("/", -1)
        return unless parts.size == 5 && parts[0] == "gid:" && parts[1] == "" && !parts[2].empty? && parts[3] == "User"
        parts[4].match?(/\A\d+\z/) ? parts[4].to_i : nil
      end

      # ActionText::Attachment.attachable_from_possibly_expired_sgid: reads the
      # payload without checking the signature. Raises where Rails raises.
      def unverified_user_id(sgid)
        message = sgid.split("--").first or return
        envelope = JSON.parse(decode64(message).force_encoding(Encoding::UTF_8))
        raise Error, "NoMethodError: dig" unless envelope.respond_to?(:dig)
        gid = if (data = envelope.dig("_rails", "data"))
          data
        elsif (data = envelope.dig("_rails", "message"))
          decode64(data)[MARSHAL_GID]
        end
        user_id(gid)
      rescue JSON::ParserError, ArgumentError, TypeError, NoMethodError => e
        raise Error, "#{e.class}: #{e.message}"
      end

      # SignedGlobalID verification (ActiveSupport::MessageVerifier, SHA1,
      # urlsafe base64, "signed_global_ids" key) for a given secret_key_base.
      class Verifier
        def initialize(secret_key_base)
          @key = OpenSSL::KDF.pbkdf2_hmac(secret_key_base, salt: "signed_global_ids", iterations: 1000, length: 64, hash: "SHA256").freeze
          freeze
        end

        # Returns the gid string, or nil when the signature, purpose or expiry fails.
        def call(sgid, purpose: "attachable", now: Time.now)
          data, _, digest = sgid.to_s.rpartition("--")
          return if data.empty? || !OpenSSL.secure_compare(digest, OpenSSL::HMAC.hexdigest("SHA1", @key, data))
          read(SGID.decode64(data), purpose, now)
        rescue ArgumentError, JSON::ParserError
          nil
        end

        def generate(gid, purpose: "attachable", expires_at: nil)
          meta = { "data" => gid }
          meta["exp"] = expires_at.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ") if expires_at
          meta["pur"] = purpose
          data = [JSON.generate({ "_rails" => meta })].pack("m0").tr("+/", "-_")
          "#{data}--#{OpenSSL::HMAC.hexdigest("SHA1", @key, data)}"
        end

        private

        def read(raw, purpose, now)
          raw = marshal_string(raw) or return if raw.start_with?("\x04\x08".b)
          value = JSON.parse(raw.force_encoding(Encoding::UTF_8))
          if value.is_a?(Hash) && (meta = value["_rails"]).is_a?(Hash)
            return if meta["exp"] && Time.iso8601(meta["exp"]) <= now
            return unless meta["pur"].to_s == purpose
            return read(SGID.decode64(meta["message"]), "", now) if meta["message"].is_a?(String)
            value = meta["data"]
          elsif !purpose.empty?
            return legacy(value, purpose, now)
          end
          value.is_a?(String) ? value : nil
        end

        # Pre-Rails 7.1 sgids: {"gid": ..., "purpose": ..., "expires_at": ...}.
        def legacy(value, purpose, now)
          return unless value.is_a?(Hash) && value["purpose"] == purpose && value["gid"].is_a?(String)
          return if value["expires_at"] && Time.iso8601(value["expires_at"]) < now
          value["gid"]
        end

        # Minimal Marshal reader for a single (possibly IVAR-wrapped) String.
        def marshal_string(raw)
          b = raw.byteslice(2..)
          b = b.byteslice(1..) if b.start_with?("I")
          return unless b.start_with?('"') && b.bytesize > 1
          first = b.getbyte(1)
          first -= 256 if first > 127
          pos = 2
          len = if first.zero? then 0
          elsif first > 4 then first - 5
          elsif first.positive?
            n = 0
            first.times { |i| n |= b.getbyte(pos + i).to_i << (8 * i) }
            pos += first
            n
          else return
          end
          return if pos + len > b.bytesize
          JSON.generate(b.byteslice(pos, len).force_encoding(Encoding::UTF_8))
        end
      end
    end
  end
end
