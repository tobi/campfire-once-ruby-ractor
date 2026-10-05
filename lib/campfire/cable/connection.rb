# frozen_string_literal: true

module Campfire
  module Cable
    # One authenticated socket. The hijacked response fiber is the writer: it
    # drains a bounded queue of pre-serialized frames, flushing once per burst.
    # A child task reads frames and runs commands. A client too slow to keep its
    # queue below QUEUE_LIMIT is dropped (as the Go hub does).
    class Connection
      QUEUE_LIMIT = 256
      MAX_FRAME = 1 << 20
      MAX_IDENTIFIER = 4096
      MAX_SUBSCRIPTIONS = 64

      attr_reader :user, :token, :subscriptions

      def self.reject_unauthorized(stream)
        stream.write(Frames::UNAUTHORIZED)
        stream.write(Frames::CLOSE)
        stream.flush
      rescue IOError, SystemCallError
        nil
      ensure
        stream.close rescue nil
      end

      def initialize(stream, user, token)
        @stream = stream
        @user = user
        @token = token
        @queue = Thread::Queue.new
        @subscriptions = {} # identifier => Channel
        @dead = false
      end

      def run
        registry = Registry.current
        @writer = Async::Task.current
        registry.add_connection(self)
        enqueue(Frames::WELCOME)
        @reader = @writer.async { read_loop }
        write_loop
      rescue Async::Stop, IOError, SystemCallError, Protocol::HTTP::Error
        nil
      ensure
        @dead = true
        @queue.close
        @reader&.stop unless Async::Task.current? == @reader
        unsubscribe_all
        registry&.remove_connection(self)
        @stream.close rescue nil
      end

      # Queue a frozen frame. Returns false once, when the client stops keeping
      # up; the caller then kills it (after it is done iterating the registry).
      def enqueue(frame)
        return true if @dead
        if @queue.size >= QUEUE_LIMIT
          @dead = true
          return false
        end
        @queue.push(frame)
        true
      rescue ClosedQueueError
        true
      end

      def dead? = @dead

      # Drop the socket now (slow client). Closing the IO wakes both the writer
      # (possibly blocked on a full socket buffer) and the reader with IOError.
      def kill!
        @dead = true
        @queue.close
        if @stream.respond_to?(:io)
          @stream.io.close rescue nil
        else
          @reader&.stop
        end
      end

      # Send a final frame (disconnect), then close.
      def close_with(frame)
        return if @queue.closed?
        @queue.push(frame)
        @queue.push(Frames::CLOSE) unless frame.equal?(Frames::CLOSE)
        @dead = true
        @queue.close
      end

      # ---- commands -------------------------------------------------------

      def receive(text)
        cmd = JSON.parse(text) rescue (return nil)
        return unless cmd.is_a?(Hash)
        identifier = cmd["identifier"]
        return unless identifier.is_a?(String) && identifier.bytesize <= MAX_IDENTIFIER
        case cmd["command"]
        when "subscribe" then subscribe(identifier)
        when "unsubscribe" then unsubscribe(identifier)
        when "message" then perform(identifier, cmd["data"])
        end
      end

      def subscribe(identifier)
        return if @subscriptions.key?(identifier) || @subscriptions.size >= MAX_SUBSCRIPTIONS
        params = JSON.parse(identifier) rescue (return nil)
        return unless params.is_a?(Hash)
        klass = Channel.find(params["channel"]) or return
        identifier = -identifier
        id_json = -Frames.json(identifier)
        channel = klass.new(self, identifier, id_json, params)
        if channel.subscribe_to_channel
          @subscriptions[identifier] = channel
          enqueue(Frames.confirm(id_json))
        else
          enqueue(Frames.reject(id_json))
        end
      end

      def unsubscribe(identifier)
        channel = @subscriptions.delete(identifier) or return
        channel.unsubscribe_from_channel
      end

      def perform(identifier, data)
        channel = @subscriptions[identifier] or return
        data = JSON.parse(data) rescue (return nil) if data.is_a?(String)
        return unless data.is_a?(Hash)
        channel.perform_action(data)
      end

      def unsubscribe_all
        subs = @subscriptions
        @subscriptions = {}
        subs.each_value do |channel|
          channel.unsubscribe_from_channel
        rescue => e
          Log.error("cable: unsubscribe", e)
        end
      end

      private

      def write_loop
        stream = @stream
        queue = @queue
        while (frame = queue.pop)
          stream.write(frame)
          stream.write(queue.pop) until queue.empty?
          stream.flush
        end
      end

      def read_loop
        framer = Protocol::WebSocket::Framer.new(@stream)
        message = nil
        loop do
          frame = framer.read_frame(MAX_FRAME)
          case frame.opcode
          when 0x1, 0x0
            data = frame.unpack
            if message
              message << data
              return if message.bytesize > MAX_FRAME
            elsif frame.opcode == 0x1
              message = data.frozen? ? +data : data
            else
              next
            end
            if frame.finished?
              text = message.force_encoding(Encoding::UTF_8)
              message = nil
              begin
                receive(text)
              rescue => e
                Log.error("cable: command", e)
              end
            end
          when 0x8
            close_with(Frames::CLOSE) unless @queue.closed?
            return
          when 0x9
            enqueue(Frames.control(0xA, frame.unpack))
          end
        end
      rescue EOFError, IOError, SystemCallError, Protocol::WebSocket::Error, Protocol::HTTP::Error
        nil
      ensure
        @queue.close
      end
    end
  end
end
