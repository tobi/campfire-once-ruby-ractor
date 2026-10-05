# frozen_string_literal: true

require "socket"

# A tiny threaded HTTP/1.1 server for outbound-request tests. The block gets a
# Request and returns [status, headers, body] (or sleeps to force a timeout).
class FakeHTTP
  Request = Struct.new(:method, :path, :headers, :body)
  REASONS = { 200 => "OK", 201 => "Created", 404 => "Not Found", 410 => "Gone", 500 => "Internal Server Error" }.freeze

  attr_reader :port, :requests

  def initialize(&handler)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Thread::Queue.new.then { [] }
    @lock = Mutex.new
    @thread = Thread.new do
      loop do
        sock = @server.accept
        Thread.new(sock) { |s| serve(s, handler) }
      rescue IOError, Errno::EBADF
        break
      end
    end
  end

  def serve(sock, handler)
    line = sock.gets or return
    method, path, = line.split(" ")
    headers = {}
    while (h = sock.gets) && h != "\r\n"
      k, v = h.split(":", 2)
      headers[k.strip.downcase] = v.strip
    end
    body = headers["content-length"] ? sock.read(headers["content-length"].to_i) : "".b
    req = Request.new(method, path, headers, body.b)
    @lock.synchronize { @requests << req }
    status, rh, rbody = handler.call(req)
    rbody = rbody.to_s.b
    out = +"HTTP/1.1 #{status} #{REASONS[status] || "X"}\r\n"
    rh.each { |k, v| out << "#{k}: #{v}\r\n" }
    out << "content-length: #{rbody.bytesize}\r\nconnection: close\r\n\r\n"
    sock.write(out.b + rbody)
  rescue IOError, SystemCallError
    nil
  ensure
    sock.close rescue nil
  end

  def close
    @server.close rescue nil
    @thread.join(1)
  end
end
