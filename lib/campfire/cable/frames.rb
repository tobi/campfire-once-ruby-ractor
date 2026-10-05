# frozen_string_literal: true

module Campfire
  module Cable
    # Pre-serialized server frames. Server-to-client WebSocket frames are never
    # masked, so one frozen binary String (header + JSON) can be written to any
    # number of sockets.
    module Frames
      module_function

      # A complete unfragmented text frame for `json`.
      def text(json)
        len = json.bytesize
        f = String.new(capacity: len + 10, encoding: Encoding::BINARY)
        if len < 126
          f << 0x81 << len
        elsif len < 65_536
          f << 0x81 << 126 << (len >> 8) << (len & 0xff)
        else
          f << 0x81 << 127
          f << [len].pack("Q>")
        end
        f << json.b
        f.freeze
      end

      # ActiveSupport::JSON.encode: JSON with <, > and & escaped (and the
      # U+2028/2029 line separators, which JSON.generate leaves alone).
      def json(value)
        s = JSON.generate(value)
        s.gsub!(ESCAPE_RE, ESCAPE) if ESCAPE_RE.match?(s)
        s
      end
      ESCAPE = { "<" => "\\u003c", ">" => "\\u003e", "&" => "\\u0026", " " => "\\u2028", " " => "\\u2029" }.freeze
      ESCAPE_RE = /[<>&  ]/

      # The `message` member of a broadcast (frozen, shareable).
      def encode_message(payload) = json(payload).freeze

      # {"identifier":"…","message":…}
      def broadcast(identifier_json, message_json)
        s = String.new(capacity: identifier_json.bytesize + message_json.bytesize + 28, encoding: Encoding::UTF_8)
        s << '{"identifier":' << identifier_json << ',"message":' << message_json << "}"
        text(s)
      end

      def confirm(identifier_json) = text(%({"identifier":#{identifier_json},"type":"confirm_subscription"}))
      def reject(identifier_json) = text(%({"identifier":#{identifier_json},"type":"reject_subscription"}))
      def ping(now) = text(%({"type":"ping","message":#{now}}))
      def disconnect(reason, reconnect) = text(%({"type":"disconnect","reason":"#{reason}","reconnect":#{reconnect ? "true" : "false"}}))

      WELCOME = text(%({"type":"welcome"}))
      UNAUTHORIZED = disconnect("unauthorized", false)
      REMOTE_RECONNECT = disconnect("remote", true)
      REMOTE = disconnect("remote", false)
      # Close frame, status 1000 (normal closure).
      CLOSE = "\x88\x02\x03\xE8".b.freeze
      PONG_EMPTY = "\x8A\x00".b.freeze

      # A control frame (pong/close echo) carrying `payload` (<= 125 bytes).
      def control(opcode, payload)
        f = String.new(capacity: payload.bytesize + 2, encoding: Encoding::BINARY)
        f << (0x80 | opcode) << payload.bytesize << payload.b
        f.freeze
      end
    end
  end
end
