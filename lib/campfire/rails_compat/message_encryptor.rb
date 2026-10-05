# frozen_string_literal: true

require_relative "message_verifier"

module Campfire
  module RailsCompat
    # ActiveSupport::MessageEncryptor with aes-256-gcm, as the encrypted cookie
    # jar builds it: "<b64 ciphertext>--<b64 12-byte IV>--<b64 16-byte tag>",
    # strict Base64, empty auth data, no separate signature.
    #
    # Immutable and Ractor-shareable: holds only the frozen key. The
    # OpenSSL::Cipher (not shareable) is kept per Ractor in Ractor-local
    # storage and re-initialised (`encrypt`/`decrypt` reset the EVP context) on
    # every call. No fiber switch can happen in between, so sharing one cipher
    # between the fibers of a Ractor is safe.
    class MessageEncryptor
      CIPHER = "aes-256-gcm"
      IV_LENGTH = 12
      AUTH_TAG_LENGTH = 16
      ENCODED_IV_LENGTH = 16       # strict base64 of 12 bytes
      ENCODED_TAG_LENGTH = 24      # strict base64 of 16 bytes
      CIPHER_KEY = :__campfire_rails_compat_gcm

      attr_reader :serializer

      def initialize(secret, serializer: :null)
        raise ArgumentError, "aes-256-gcm needs a 32-byte key" unless secret.bytesize == 32
        @secret = secret.b.freeze
        @serializer = serializer
        Ractor.make_shareable(self)
      end

      def encrypt_and_sign(value, purpose: nil, expires_at: nil)
        encrypt(Metadata.serialize_with_metadata(@serializer, value, purpose, expires_at))
      end

      # The value or nil.
      def decrypt_and_verify(message, purpose: nil, now: Time.now)
        v = read(message, purpose, Util.now_ns(now))
        Util.invalid?(v) ? nil : v
      end

      def read(message, purpose, now_ns)
        plain = decrypt(message) or return Util::INVALID_FORMAT
        Metadata.deserialize_with_metadata(@serializer, plain, purpose, now_ns, false)
      end

      # Raw decrypted bytes (before envelope handling) or nil.
      def decrypt(message)
        return nil unless message.is_a?(String) && message.ascii_only?
        len = message.bytesize
        tag_start = len - ENCODED_TAG_LENGTH
        iv_start = tag_start - 2 - ENCODED_IV_LENGTH
        ct_end = iv_start - 2
        return nil if ct_end < 0
        return nil unless message.getbyte(tag_start - 2) == 45 && message.getbyte(tag_start - 1) == 45 &&
          message.getbyte(ct_end) == 45 && message.getbyte(ct_end + 1) == 45
        tag = Util.strict_decode64(message.byteslice(tag_start, ENCODED_TAG_LENGTH)) or return nil
        iv = Util.strict_decode64(message.byteslice(iv_start, ENCODED_IV_LENGTH)) or return nil
        ct = Util.strict_decode64(message.byteslice(0, ct_end)) or return nil
        return nil unless tag.bytesize == AUTH_TAG_LENGTH && iv.bytesize == IV_LENGTH

        c = cipher
        c.decrypt
        c.key = @secret
        c.iv = iv
        c.auth_tag = tag
        c.auth_data = ""
        out = ct.empty? ? +"" : c.update(ct)
        out << c.final
      rescue OpenSSL::Cipher::CipherError, ArgumentError
        nil
      end

      def encrypt(plain)
        c = cipher
        c.encrypt
        c.key = @secret
        iv = Util.random_bytes(IV_LENGTH)
        c.iv = iv
        c.auth_data = ""
        ct = plain.empty? ? +"" : c.update(plain)
        ct << c.final
        tag = c.auth_tag(AUTH_TAG_LENGTH)
        out = Util.strict_encode64(ct)
        out << "--" << Util.strict_encode64(iv) << "--" << Util.strict_encode64(tag)
      end

      def inspect = "#<#{self.class.name} #{CIPHER} #{@serializer}>"

      private

      def cipher
        Ractor[CIPHER_KEY] ||= OpenSSL::Cipher.new(CIPHER)
      end
    end
  end
end
