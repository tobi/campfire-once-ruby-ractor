# frozen_string_literal: true

require "kino"
require_relative "cable"

module Campfire
  # Server on Kino (CAMPFIRE_SERVER=kino): Kino owns the worker Ractors, each one's thread runs
  # Campfire's fiber reactor (work), and the cable runs on Kino's native WebSockets.
  module KinoServer
    module_function

    # Requests a worker runs at once, open sockets aside (Falcon sets no cap): 16 measured the
    # lowest p99 on the room and messages pages, and lost to 32 nowhere.
    CONCURRENCY = 16
    HEARTBEAT = "cable:heartbeat" # the topic of Rails' pings

    def run(config)
      Server.raise_fd_limit
      Log.start
      Writer.start
      DB.checkpointer(config.database_path) if config.background_checkpoints
      Bus.start(config.workers)
      Jobs.start(config.job_workers, config)
      # Kino drains and returns where Falcon exits!: end the job Ractors' loops and give their jobs up
      # to a second, or Ruby's teardown waits about a second for each job Ractor.
      at_exit do
        Jobs::PORTS.each { |port| port.send(nil) rescue nil } # raises if that Ractor has ended
        Thread.new { Jobs::RACTORS.each { |r| r.join rescue nil } }.join(1)
      end
      Thread.new do # one publish pings every socket of the process
        loop do
          sleep Cable::Registry::BEAT_INTERVAL
          Kino::WebSocket.publish(HEARTBEAT, %({"type":"ping","message":#{Time.now.to_i}}))
        end
      end
      Kino::Server.new(self, workers: config.workers, bind: config.bind, port: config.port,
        max_body_size: nil, # no limit, as on Falcon
        io_shards: true, # HTTP and WebSocket I/O on per-thread shards: one thread hop less
        worker_loop: Ractor.shareable_proc { |worker| KinoServer.work(worker) }, after_boot: lambda do
          Log.info "campfire: #{config.workers} ractors on Kino #{Kino::VERSION} listening on " \
            "http://#{config.bind}:#{config.port}, JIT: #{Server.jit} (#{RUBY_DESCRIPTION})"
          Log.flush # the main Ractor has no flush timer
        end).run
    end

    # A worker Ractor's thread: Server.work with Kino's loop in place of Falcon's, a task per job.
    def work(worker)
      DB.connection # open (and warm) before the first request
      Sync do |task|
        Log.attach(task)
        Bus.attach(task)
        worker.serve(concurrency: CONCURRENCY) do |job|
          task.async { job.call rescue Log.error("kino: worker_loop job", $!) } # Kino's handling failed
        end
      end
    end

    # Rack in, Rack out. Kino writes a buffered body (nearly every response) with a Content-Length.
    def call(env)
      response = (Ractor[:campfire_app] ||= App.new).call(Request.new(env))
      fields = response.headers.to_a
      headers = fields.to_h
      if headers.size < fields.size # a name repeats: Kino writes each element of an Array value as a line
        headers = {}
        fields.each { |name, value| headers[name] = (prior = headers[name]) ? [*prior, value] : value }
      end
      body = response.body
      [response.status, headers, Protocol::HTTP::Body::Buffered === body ? body.chunks : body || Responses::EMPTY]
    end

    # Kino's env as the request Falcon hands App: the path with its query, and Host as the authority.
    # Common header names come from a table: deriving them doubled the time a browser's headers take.
    class Request < Protocol::HTTP::Request
      NAMES = %w[
        accept accept-charset accept-encoding accept-language alt-used authorization cache-control connection
        content-encoding content-language cookie dnt expect forwarded if-match if-modified-since if-none-match
        if-range if-unmodified-since keep-alive origin pragma priority purpose range referer sec-ch-ua
        sec-ch-ua-mobile sec-ch-ua-platform sec-fetch-dest sec-fetch-mode sec-fetch-site sec-fetch-user
        sec-purpose sec-websocket-extensions sec-websocket-key sec-websocket-protocol sec-websocket-version te
        transfer-encoding turbo-frame upgrade upgrade-insecure-requests user-agent via x-api-key x-csrf-token
        x-forwarded-for x-forwarded-host x-forwarded-port x-forwarded-proto x-real-ip x-request-id
        x-requested-with x-turbo-request-id
      ].to_h { |name| ["HTTP_#{name.upcase.tr("-", "_")}", name] }
        .merge("CONTENT_TYPE" => "content-type", "CONTENT_LENGTH" => "content-length", "HTTP_HOST" => false)
        .freeze

      attr_reader :env

      def initialize(env)
        @env = env
        fields = []
        keys = env.keys
        i = -1
        while (key = keys[i += 1])
          if (name = NAMES[key])
            fields << [name, env[key]]
          elsif name.nil? && key.start_with?("HTTP_")
            (name = key.byteslice(5, key.bytesize - 5)).downcase!
            name.tr!("_", "-")
            fields << [name, env[key]]
          end
        end
        query = env["QUERY_STRING"]
        path = query.empty? ? env["PATH_INFO"] : "#{env["PATH_INFO"]}?#{query}"
        super(env["rack.url_scheme"], env["HTTP_HOST"], env["REQUEST_METHOD"], path, env["SERVER_PROTOCOL"],
          Protocol::HTTP::Headers.new(fields), Protocol::Rack::Body::InputWrapper.new(env["rack.input"]),
          Protocol::Rack::Request.protocol(env))
      end

      def remote_address = Addrinfo.tcp(@env["REMOTE_ADDR"], 0)
    end

    # Cable broadcasts skip the Bus: one Kino publish, from any Ractor, reaches every worker's sockets.
    module BusPublish
      def publish(msg)
        return super unless msg[0] == :cable
        Kino::WebSocket.publish(msg[1], msg[2]) or
          Log.error("cable: broadcast to #{msg[1]} dropped, Kino's fan-out queue is full")
      end
    end
    Bus.singleton_class.prepend(BusPublish)
  end

  module Cable
    # A Connection on a Kino socket, which Kino frames and whose events it runs in order on the
    # reactor of the worker that accepted it, in place of Connection#run's fibers.
    class KinoConnection < Connection
      attr_reader :ws

      def on_open(ws)
        @ws = ws
        Registry.current.add_connection(self)
        enqueue(Frames::WELCOME)
        ws.subscribe(KinoServer::HEARTBEAT)
      end

      def on_message(_ws, data)
        receive(data) if data.encoding == Encoding::UTF_8 # binary is ignored, as on Falcon
      rescue => e # logged, and the socket stays open, as on Falcon (Kino would drop it)
        Log.error("cable: command", e)
      end

      def on_close(_ws)
        unsubscribe_all
        Registry.current.remove_connection(self)
      end

      # Kino holds 256 frames per socket, as QUEUE_LIMIT; a client that falls behind is dropped.
      def enqueue(frame) = @dead || @ws.write_raw(frame) || @ws.abort

      def close_with(frame)
        (@ws.write_raw(frame); @ws.close(1000)) unless @dead
        @dead = true
      end
    end

    # A stream subscription is a Kino topic subscription in Frames.broadcast's envelope, so Kino
    # frames a broadcast once per identifier. Sockets and users stay in the Registry.
    module KinoStreams
      def stream_from(stream, sub) = sub.connection.ws.subscribe(stream, prefix: envelope(sub), suffix: "}")
      def stop_stream(stream, sub) = sub.connection.ws.unsubscribe(stream, prefix: envelope(sub))
      def envelope(sub) = %({"identifier":#{sub.identifier_json},"message":)
    end
    Registry.prepend(KinoStreams)

    # Cable.call's checks and subprotocol, answered by handing the socket to Kino (rack.upgrade).
    module KinoEndpoint
      def call(request)
        return not_found unless request.env["rack.upgrade?"] == :websocket && allowed_origin?(request)
        user, token = authenticate(request)
        protocol = (request.headers["sec-websocket-protocol"].to_s.split(",").map!(&:strip) & PROTOCOLS).first
        headers = protocol ? [["sec-websocket-protocol", protocol]] : []
        headers << ["x-campfire-worker", Ractor.current.name[/\d+\z/]] if DEBUG_WORKER
        request.env["rack.upgrade"] = user ? KinoConnection.new(nil, user, token) : KinoReject
        Responses.build(101, headers, nil)
      end
    end
    singleton_class.prepend(KinoEndpoint)

    # Connection.reject_unauthorized on a Kino socket (a fresh socket's queue takes any frame).
    module KinoReject
      def self.on_open(ws) = ws.write_raw(Frames::UNAUTHORIZED) && ws.close(1000)
    end
  end
end
