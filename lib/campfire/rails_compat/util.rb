# frozen_string_literal: true

require "openssl"
require "json"

module Campfire
  module RailsCompat
    # Low-level helpers shared by the verifiers: Ruby's Base64 flavours (via
    # pack/unpack, so the `base64` gem is not needed), ActiveSupport::JSON
    # encoding, ISO 8601 expiry timestamps and constant-time comparison.
    #
    # Everything here is a module function over frozen constants, so it can be
    # called from any Ractor.
    module Util
      # Sentinels returned internally instead of raising (exceptions are slow and
      # nil/false are valid payloads). Symbols are shareable, and JSON never
      # produces symbols, so they can't collide with a real value.
      INVALID_FORMAT = :__rails_compat_invalid_format        # bad signature / encoding
      INVALID_SERIALIZATION = :__rails_compat_invalid_serialization # authentic, but undecodable
      INVALID_CONTENT = :__rails_compat_invalid_content      # expired or wrong purpose

      HTML_ESCAPE = { "<" => "\\u003c", ">" => "\\u003e", "&" => "\\u0026" }.freeze
      HTML_ESCAPE_RE = /[<>&]/

      # ActiveSupport::JSON.decode == ::JSON.parse. json >= 3 raises on duplicate
      # keys by default; the json 2.x the reference app runs keeps the last one.
      PARSE_OPTS = { allow_duplicate_key: true }.freeze
      # ::JSON.load (what the `JSON` serializer of Turbo / signed ids uses).
      LOAD_OPTS = { allow_duplicate_key: true, allow_nan: true }.freeze

      MARSHAL_SIGNATURE = "\x04\x08".b.freeze
      # SerializerWithFallback::JsonWithFallback::JSON_START_WITH
      JSON_START_WITH = /\A(?:[{\["]|-?\d|true|false|null)/

      BLANK_RE = /\A[[:space:]]*\z/
      URLSAFE_CHARS_RE = /[-_]/

      module_function

      # ---- Base64 ---------------------------------------------------------

      # Base64.strict_encode64
      def strict_encode64(bin)
        [bin].pack("m0")
      end

      # Base64.urlsafe_encode64(bin, padding: false)
      def urlsafe_encode64_unpadded(bin)
        s = [bin].pack("m0")
        s.tr!("+/", "-_")
        s.delete!("=")
        s
      end

      # Base64.urlsafe_encode64(bin) (padded), as GlobalID::Verifier writes.
      def urlsafe_encode64_padded(bin)
        s = [bin].pack("m0")
        s.tr!("+/", "-_")
        s
      end

      # Base64.strict_decode64, or nil.
      def strict_decode64(str)
        str.unpack1("m0")
      rescue ArgumentError
        nil
      end

      # Base64.urlsafe_decode64, or nil. Like Ruby's, it accepts either alphabet
      # (even mixed) and optional padding. It is a superset of strict decoding,
      # which is why MessageVerifier's "try one alphabet, then the other" is
      # equivalent to calling this once.
      def urlsafe_decode64(str)
        len = str.bytesize
        if !str.end_with?("=") && (len & 3) != 0
          s = str.ljust((len + 3) & ~3, "=")
          s.tr!("-_", "+/")
        elsif URLSAFE_CHARS_RE.match?(str)
          s = str.tr("-_", "+/")
        else
          s = str
        end
        s.unpack1("m0")
      rescue ArgumentError
        nil
      end

      # ---- JSON -----------------------------------------------------------

      # ActiveSupport::JSON.encode with escape_html_entities_in_json (the default)
      # and, as load_defaults 8.1+ sets, *without* escaping U+2028/U+2029.
      # `<`, `>`, `&` can only occur inside JSON strings, so a global gsub is safe.
      def as_json_encode(value)
        s = JSON.generate(value)
        HTML_ESCAPE_RE.match?(s) ? s.gsub(HTML_ESCAPE_RE, HTML_ESCAPE) : s
      end

      # ::JSON.generate / JSON.dump (no HTML escaping).
      def json_dump(value)
        JSON.generate(value)
      end

      # json >= 2.10 exposes JSON::Parser.parse(source, opts), which is what
      # JSON.parse calls; using it directly skips a kwargs Hash per call.
      if JSON::Parser.respond_to?(:parse) && JSON::Parser.method(:parse).arity == 2
        # ActiveSupport::JSON.decode; raises JSON::ParserError.
        def as_json_decode(str) = JSON::Parser.parse(str, PARSE_OPTS)

        # ::JSON.load; "" is nil.
        def json_load(str) = str.empty? ? nil : JSON::Parser.parse(str, LOAD_OPTS)
      else
        def as_json_decode(str) = JSON.parse(str, **PARSE_OPTS)
        def json_load(str) = str.empty? ? nil : JSON.parse(str, **LOAD_OPTS)
      end

      # ---- Marshal (subset) ------------------------------------------------

      # Loads a marshaled String (`Marshal.dump("gid://campfire/User/1")`, what
      # Rails 7.0-era messages carry). Anything else returns nil: we never run
      # the real Marshal.load on cookie/message payloads.
      def marshal_load_string(bin)
        return nil unless bin.start_with?(MARSHAL_SIGNATURE)
        i = 2
        i += 1 if bin.getbyte(i) == 0x49 # 'I' (has ivars, e.g. encoding)
        return nil unless bin.getbyte(i) == 0x22 # '"'
        i += 1
        c = bin.getbyte(i) or return nil
        i += 1
        c -= 256 if c > 127
        len =
          if c == 0 then 0
          elsif c >= 5 then c - 5
          elsif c > 0
            n = 0
            c.times { |k| b = bin.getbyte(i + k) or return nil; n |= b << (8 * k) }
            i += c
            n
          else
            return nil # negative length
          end
        return nil if i + len > bin.bytesize
        s = bin.byteslice(i, len)
        s.force_encoding(Encoding::UTF_8)
        s.valid_encoding? ? s : s.force_encoding(Encoding::BINARY)
      end

      # ---- Time -----------------------------------------------------------

      # Time#iso8601(3) in UTC ("2046-01-01T12:00:00.000Z"; fraction truncated).
      def iso8601_ms(time)
        time.getutc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      end

      # Time#httpdate ("Mon, 01 Jan 2046 12:00:00 GMT"). Ruby's strftime names are
      # locale independent.
      def httpdate(time)
        time.getutc.strftime("%a, %d %b %Y %H:%M:%S GMT")
      end

      # `20.years.from_now` (calendar years; Feb 29 clamps to Feb 28).
      def years_from(time, years)
        t = time.getutc
        y = t.year + years
        d = t.day
        d = 28 if t.month == 2 && d == 29 && !leap?(y)
        Time.utc(y, t.month, d, t.hour, t.min, t.sec + t.subsec)
      end

      def leap?(y) = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0

      # `now` as integer nanoseconds since the epoch. Accepts Time or Numeric
      # (epoch seconds).
      def now_ns(now)
        case now
        when Time then now.to_i * 1_000_000_000 + now.nsec
        when Integer then now * 1_000_000_000
        when Numeric then (now * 1_000_000_000).to_i
        else
          t = now.to_time
          t.to_i * 1_000_000_000 + t.nsec
        end
      end

      # Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant).
      def days_from_civil(y, m, d)
        y -= 1 if m <= 2
        era = y.div(400)
        yoe = y - era * 400
        doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        era * 146_097 + doe - 719_468
      end

      ISO8601_RE = /\A\s*(-?\d{4,})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?(Z|[+-]\d\d(?::?\d\d)?)?\s*\z/i

      # Parses the `exp` of a metadata envelope (Time.iso8601) to epoch
      # nanoseconds, or nil if it isn't a valid timestamp. The canonical
      # 24-byte form Rails writes is parsed without allocating.
      def parse_iso8601_ns(s)
        return nil unless s.is_a?(String)
        if s.bytesize == 24 && s.getbyte(23) == 90 && s.getbyte(4) == 45 && s.getbyte(7) == 45 &&
            s.getbyte(10) == 84 && s.getbyte(13) == 58 && s.getbyte(16) == 58 && s.getbyte(19) == 46
          y = dig(s, 0) * 1000 + dig(s, 1) * 100 + dig(s, 2) * 10 + dig(s, 3)
          mo = dig(s, 5) * 10 + dig(s, 6)
          d = dig(s, 8) * 10 + dig(s, 9)
          h = dig(s, 11) * 10 + dig(s, 12)
          mi = dig(s, 14) * 10 + dig(s, 15)
          se = dig(s, 17) * 10 + dig(s, 18)
          ms = dig(s, 20) * 100 + dig(s, 21) * 10 + dig(s, 22)
          if y >= 0 && mo >= 0 && d >= 0 && h >= 0 && mi >= 0 && se >= 0 && ms >= 0
            return nil unless valid_civil?(y, mo, d, h, mi, se)
            return (((days_from_civil(y, mo, d) * 24 + h) * 60 + mi) * 60 + se) * 1_000_000_000 + ms * 1_000_000
          end
        end
        m = ISO8601_RE.match(s) or return nil
        y, mo, d, h, mi, se = m[1].to_i, m[2].to_i, m[3].to_i, m[4].to_i, m[5].to_i, m[6].to_i
        return nil unless valid_civil?(y, mo, d, h, mi, se)
        frac = m[7] ? (m[7] + "000000000")[0, 9].to_i : 0
        offset = 0
        if (z = m[8]) && z != "Z" && z != "z"
          sign = z.start_with?("-") ? -1 : 1
          digits = z.delete(":+-")
          offset = sign * (digits[0, 2].to_i * 3600 + digits[2, 2].to_i * 60)
        end
        ((((days_from_civil(y, mo, d) * 24 + h) * 60 + mi) * 60 + se) - offset) * 1_000_000_000 + frac
      end

      def valid_civil?(y, mo, d, h, mi, se)
        mo.between?(1, 12) && d >= 1 && d <= days_in_month(y, mo) && h <= 24 && mi <= 59 && se <= 60
      end

      DAYS_IN_MONTH = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].freeze
      def days_in_month(y, m) = (m == 2 && leap?(y)) ? 29 : DAYS_IN_MONTH[m]

      # Digit at byte offset i, or a large negative number if not a digit.
      def dig(s, i)
        b = s.getbyte(i) - 48
        (b >= 0 && b <= 9) ? b : -100_000
      end

      # `Object#blank?` for the strings a signed message is split into.
      def blank?(s) = s.empty? || BLANK_RE.match?(s)

      # `Object#to_s` of a purpose found in an envelope.
      def purpose_to_s(v)
        v.nil? ? "" : (v.is_a?(String) ? v : v.to_s)
      end

      def invalid?(v)
        v.equal?(INVALID_FORMAT) || v.equal?(INVALID_SERIALIZATION) || v.equal?(INVALID_CONTENT)
      end

      # Random bytes from the OS CSPRNG (Ractor safe).
      def random_bytes(n) = Random.urandom(n)
    end
  end
end
