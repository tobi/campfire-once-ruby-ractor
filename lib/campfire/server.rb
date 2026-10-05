# frozen_string_literal: true

require "socket"
require "falcon/server"
require "async/http/endpoint"
require "io/endpoint/bound_endpoint"

module Campfire
  # Binds one listening socket in the main Ractor and runs a Falcon server on
  # it in each of N worker Ractors. Each worker owns its own SQLite connection,
  # caches and fiber reactor; the kernel load-balances accept() across them.
  module Server
    module_function

    def run(config)
      raise_fd_limit
      sockets =Socket.tcp_server_sockets(config.bind, config.port)
      sockets.each { |s| s.listen(Socket::SOMAXCONN) }
      fds = Ractor.make_shareable(sockets.map(&:fileno))
      url = Ractor.make_shareable("http://#{config.bind}:#{config.port}")

      Log.start
      Writer.start
      DB.checkpointer(config.database_path) if config.background_checkpoints
      Bus.start(config.workers)
      Jobs.start(config.job_workers, config)
      workers = Array.new(config.workers) do |index|
        Ractor.new(fds, url, index, name: "worker-#{index}") do |fds, url, index|
          Campfire::Server.work(fds, url, index)
        end
      end
      Log.info "campfire: #{config.workers} ractors listening on #{url} (ruby #{RUBY_VERSION}, YJIT #{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?})"

      %w[INT TERM].each { |sig| trap(sig) { exit!(0) } }
      workers.each(&:join)
    end

    # Every cable client holds a socket. The usual soft limit (1024) let ~1000 clients
    # exhaust fds; accept() then failed with EMFILE and the server stopped answering.
    # Go raises the soft limit to the hard one at startup; do the same.
    def raise_fd_limit
      soft, hard = Process.getrlimit(:NOFILE)
      Process.setrlimit(:NOFILE, hard, hard) if soft < hard
    rescue SystemCallError
      nil
    end

    def work(fds, url, index)
      Ractor[:worker_index] = index
      DB.connection # open (and warm) before the first request
      sockets = fds.map { |fd| Socket.for_fd(fd).tap { |s| s.autoclose = false } }
      endpoint = Async::HTTP::Endpoint.parse(url)
      bound = IO::Endpoint::BoundEndpoint.new(endpoint, sockets)
      Sync do |task|
        Log.attach(task)
        Bus.attach(task)
        Cable.attach(task)
        server = Falcon::Server.new(App.new, bound, protocol: endpoint.protocol, scheme: "http")
        server.run.wait
      end
    rescue Exception => e
      Log.error("worker #{index} crashed", e)
      raise
    end
  end
end
