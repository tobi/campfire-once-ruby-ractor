# frozen_string_literal: true

require "protocol/http/response"
require "protocol/http/headers"
require "protocol/http/body/buffered"
require "uri"

module Campfire
  # Rack-compatible query/form decoding into Rails-style nested params
  # (`message[body]=x` => {"message" => {"body" => "x"}}).
  module Params
    module_function

    def decode(str, into = {})
      return into if str.nil? || str.empty?
      pos = 0
      len = str.bytesize
      while pos < len
        amp = str.byteindex("&", pos) || len
        if amp > pos
          eq = str.byteindex("=", pos)
          if eq && eq < amp
            key = unescape(str.byteslice(pos, eq - pos))
            val = unescape(str.byteslice(eq + 1, amp - eq - 1))
          else
            key = unescape(str.byteslice(pos, amp - pos))
            val = nil
          end
          assign(into, key, val)
        end
        pos = amp + 1
      end
      into
    end

    def unescape(s)
      return s unless s.include?("%") || s.include?("+")
      URI.decode_www_form_component(s)
    rescue ArgumentError
      s
    end

    def assign(into, key, val)
      if (br = key.index("["))
        head = key[0, br]
        rest = key[br..]
        target = (into[head] ||= rest.start_with?("[]") ? [] : {})
        while (m = rest.match(/\A\[([^\]]*)\](.*)\z/))
          sub, rest = m[1], m[2]
          if rest.empty?
            if sub.empty?
              target << val if target.is_a?(Array)
            elsif target.is_a?(Hash)
              target[sub] = val
            end
            return
          end
          nxt = rest.start_with?("[]") ? [] : {}
          if sub.empty?
            target << nxt if target.is_a?(Array)
          elsif target.is_a?(Hash)
            nxt = (target[sub] ||= nxt)
          end
          target = nxt
        end
      else
        into[key] = val
      end
    end

    def escape(s) = URI.encode_www_form_component(s.to_s)

    def to_query(hash)
      hash.map { |k, v| "#{escape(k)}=#{escape(v)}" }.join("&")
    end
  end

  # Thin response helpers shared by controllers.
  module Responses
    TEXT_HTML = "text/html; charset=utf-8"
    TURBO_STREAM = "text/vnd.turbo-stream.html; charset=utf-8"
    JSON_TYPE = "application/json; charset=utf-8"
    EMPTY = [].freeze

    module_function

    def build(status, headers, body)
      body = body.nil? || body.empty? ? nil : Protocol::HTTP::Body::Buffered.new([body], body.bytesize)
      Protocol::HTTP::Response[status, Protocol::HTTP::Headers.new(headers), body]
    end
  end
end
