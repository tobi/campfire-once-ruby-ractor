require "bundler/setup"
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/http/response"
require "socket"
require_relative "../lib/ractor_compat"
RactorCompat.share_constants!

lsock = Socket.tcp_server_sockets("127.0.0.1", 9393).first
lsock.listen(1024)

rs = 4.times.map do |i|
  Ractor.new(lsock.fileno, i) do |fd, idx|
    begin
      sock = Socket.for_fd(fd); sock.autoclose = false
      Async do
        app = ->(req) { Protocol::HTTP::Response[200, {"content-type" => "text/plain"}, ["hello #{idx}\n"]] }
        ep = Async::HTTP::Endpoint.parse("http://127.0.0.1:9393")
        Async::HTTP::Server.new(app, IO::Endpoint::BoundEndpoint.new(ep, [sock]), protocol: ep.protocol, scheme: "http").run.wait
      end
    rescue Exception => e
      [e.class, e.message, e.backtrace.first(10)]
    end
  end
end
sleep 1
puts `curl -s http://127.0.0.1:9393/ http://127.0.0.1:9393/ http://127.0.0.1:9393/`; system("/home/tobi/src/once/ref-rust/bench/loadgen/target/release/loadgen http --base http://127.0.0.1:9393 --cookie x --path / --conc 16 --duration 3")
