# frozen_string_literal: true

require "socket"
require "json"
require "securerandom"
require "timeout"

# A tiny blocking WebSocket client (RFC 6455) for Action Cable tests. Plain
# sockets, no fiber scheduler, so it can run from any test.
class CableClient
  attr_reader :status, :headers, :protocol

  def initialize(host, port, cookie: nil, origin: :auto, protocols: "actioncable-v1-json, actioncable-unsupported", path: "/cable")
    @sock = TCPSocket.new(host, port)
    @sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    key = [SecureRandom.bytes(16)].pack("m0")
    req = +"GET #{path} HTTP/1.1\r\nHost: #{host}:#{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
      "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n"
    req << "Sec-WebSocket-Protocol: #{protocols}\r\n" if protocols
    origin = "http://#{host}:#{port}" if origin == :auto
    req << "Origin: #{origin}\r\n" if origin
    req << "Cookie: #{cookie}\r\n" if cookie
    req << "\r\n"
    @sock.write(req)
    line = @sock.gets("\r\n")
    @status = line.to_s.split(" ")[1].to_i
    @headers = {}
    while (l = @sock.gets("\r\n")) && l != "\r\n"
      k, v = l.chomp.split(": ", 2)
      @headers[k.downcase] = v
    end
    @protocol = @headers["sec-websocket-protocol"]
    @buffer = +"".b
  end

  def upgraded? = @status == 101

  def send_json(obj) = send_text(JSON.generate(obj))

  def send_text(text, opcode: 1, fin: true)
    data = text.b
    mask = SecureRandom.bytes(4)
    frame = [(fin ? 0x80 : 0) | opcode].pack("C")
    if data.bytesize < 126
      frame << [0x80 | data.bytesize].pack("C")
    elsif data.bytesize < 65_536
      frame << [0x80 | 126, data.bytesize].pack("Cn")
    else
      frame << [0x80 | 127, data.bytesize].pack("CQ>")
    end
    frame << mask
    masked = data.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i % 4) }.pack("C*")
    @sock.write(frame << masked)
  end

  def subscribe(identifier) = send_json(command: "subscribe", identifier: identifier.is_a?(String) ? identifier : JSON.generate(identifier))
  def unsubscribe(identifier) = send_json(command: "unsubscribe", identifier: identifier.is_a?(String) ? identifier : JSON.generate(identifier))
  def perform(identifier, data) = send_json(command: "message", identifier: identifier.is_a?(String) ? identifier : JSON.generate(identifier), data: JSON.generate(data))

  # Next frame as [opcode, payload] or nil on EOF/timeout.
  def read_frame(timeout = 5)
    head = read_exact(2, timeout) or return nil
    b0, b1 = head.unpack("CC")
    len = b1 & 0x7f
    len = read_exact(2, timeout).unpack1("n") if len == 126
    len = read_exact(8, timeout).unpack1("Q>") if len == 127
    payload = len.zero? ? +"" : read_exact(len, timeout)
    [b0 & 0x0f, payload]
  end

  # Next text message parsed as JSON (skipping pings unless asked for).
  def read_message(timeout = 5, pings: false)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return nil if left <= 0
      op, payload = read_frame(left)
      return nil unless op
      return [:close, payload] if op == 8
      next unless op == 1
      msg = JSON.parse(payload.force_encoding(Encoding::UTF_8))
      next if !pings && msg["type"] == "ping"
      return msg
    end
  end

  def raw_read_text(timeout = 5)
    loop do
      op, payload = read_frame(timeout)
      return nil unless op
      return payload.force_encoding(Encoding::UTF_8) if op == 1
      return nil if op == 8
    end
  end

  def close
    @sock.close unless @sock.closed?
  end

  private

  def read_exact(n, timeout)
    while @buffer.bytesize < n
      return nil unless @sock.wait_readable(timeout)
      chunk = @sock.read_nonblock(65_536, exception: false)
      return nil if chunk.nil?
      next if chunk == :wait_readable
      @buffer << chunk
    end
    out = @buffer.byteslice(0, n)
    @buffer = @buffer.byteslice(n, @buffer.bytesize - n)
    out
  end
end
