# frozen_string_literal: true

require_relative "util"

module Campfire
  module RailsCompat
    # Rack's cookie wire format: escaping (URI.encode_www_form_component),
    # unescaping, Cookie header parsing (Rack::Utils.parse_cookies_header) and
    # Set-Cookie generation (Rack::Utils.set_cookie_header) as Rails emits it.
    module Cookies
      SAFE_RE = /\A[*\-.0-9A-Z_a-z]*\z/
      UNSAFE_RE = /[^*\-.0-9A-Z_a-z]/n
      ESCAPE_TABLE = Ractor.make_shareable((0..255).to_h { |b|
        c = b.chr
        [c, c == " " ? "+" : format("%%%02X", b)]
      })
      NEEDS_UNESCAPE_RE = /[%+]/
      BAD_ESCAPE_RE = /%(?!\h\h)/
      UNESCAPE_RE = /\+|%\h\h/n
      UNESCAPE_TABLE = Ractor.make_shareable(begin
        t = { "+" => " ".b }
        256.times { |b| h = format("%02X", b); c = b.chr; t["%#{h}"] = c; t["%#{h.downcase}"] = c; t["%#{h[0]}#{h[1].downcase}"] = c; t["%#{h[0].downcase}#{h[1]}"] = c }
        t
      end)
      VALID_KEY_RE = /\A[!#$%&'*+\-.\^_`|~0-9a-zA-Z]+\z/
      EPOCH_HTTPDATE = "Thu, 01 Jan 1970 00:00:00 GMT"

      module_function

      # Rack::Utils.escape: alphanumerics and `*-._` stay, space is `+`, the
      # rest is %XX of the UTF-8 bytes.
      def escape(value)
        s = value.to_s
        return s if SAFE_RE.match?(s)
        s.b.gsub(UNSAFE_RE, ESCAPE_TABLE).force_encoding(Encoding::US_ASCII)
      end

      # Rack's `unescape(value) rescue value`: `+` is space, %XX decoded, and a
      # malformed escape leaves the value untouched.
      def unescape(wire)
        return wire unless NEEDS_UNESCAPE_RE.match?(wire)
        return wire if BAD_ESCAPE_RE.match?(wire)
        wire.b.gsub(UNESCAPE_RE, UNESCAPE_TABLE).force_encoding(Encoding::UTF_8)
      end

      # The (unescaped) value of cookie `name` in a Cookie header, or nil.
      # Same semantics as Rack (pairs split on /; */, first occurrence wins, keys
      # compared verbatim) without building a Hash.
      def cookie_value(header, name)
        return nil unless header
        return parse_cookie_header(header)[name] unless header.ascii_only?
        nlen = name.bytesize
        pos = 0
        while (i = header.byteindex(name, pos))
          after = i + nlen
          if header.getbyte(after) == 61 && boundary?(header, i) # '='
            stop = header.byteindex(";", after + 1) || header.bytesize
            raw = header.byteslice(after + 1, stop - after - 1)
            return unescape(raw)
          end
          pos = i + 1
        end
        nil
      end

      def boundary?(header, i)
        return true if i == 0
        j = i - 1
        j -= 1 while j >= 0 && header.getbyte(j) == 32
        # Only spaces before us: at the header start they belong to the key.
        j >= 0 && header.getbyte(j) == 59 # ';'
      end

      # Rack::Utils.parse_cookies_header (full Hash).
      def parse_cookie_header(header)
        cookies = {}
        return cookies unless header
        header.split(/; */).each do |cookie|
          next if cookie.empty?
          key, value = cookie.split("=", 2)
          next if cookies.key?(key)
          cookies[key] = value && unescape(value)
        end
        cookies
      end

      # Rack::Utils.set_cookie_header as Rails' cookie jar calls it (Rails adds
      # path "/" and samesite=lax by default; ActionDispatch::SSL adds secure).
      def set_cookie_header(name, value, path: "/", domain: nil, max_age: nil, expires: nil,
                            secure: false, httponly: false, same_site: :lax, partitioned: false)
        raise ArgumentError, "invalid cookie key: #{name.inspect}" unless VALID_KEY_RE.match?(name)
        out = +"#{name}=#{escape(value)}"
        out << "; domain=" << domain if domain
        out << "; path=" << path if path
        out << "; max-age=" << max_age.to_s if max_age
        out << "; expires=" << (expires.is_a?(String) ? expires : Util.httpdate(expires)) if expires
        out << "; secure" if secure
        out << "; httponly" if httponly
        case same_site
        when nil, false then nil
        when :none, "None", :None, "none" then out << "; samesite=none"
        when :lax, "Lax", :Lax, "lax" then out << "; samesite=lax"
        when true, :strict, "Strict", :Strict, "strict" then out << "; samesite=strict"
        else raise ArgumentError, "Invalid :same_site value: #{same_site.inspect}"
        end
        out << "; partitioned" if partitioned
        out
      end

      # `cookies.delete(name)`: "name=; path=/; max-age=0; expires=Thu, 01 Jan
      # 1970 00:00:00 GMT; samesite=lax".
      def delete_cookie_header(name, path: "/", domain: nil, secure: false, same_site: :lax)
        set_cookie_header(name, "", path: path, domain: domain, max_age: "0", expires: EPOCH_HTTPDATE,
          secure: secure, same_site: same_site)
      end
    end
  end
end
