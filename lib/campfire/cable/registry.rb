# frozen_string_literal: true

module Campfire
  module Cable
    # This worker Ractor's sockets and stream subscriptions. Only fibers of the
    # owning Ractor touch it, so plain Hashes suffice.
    class Registry
      BEAT_INTERVAL = 3

      def self.current = (Ractor[:cable_registry] ||= new)

      attr_reader :streams, :connections

      def initialize
        @streams = {}      # stream name => { Subscription => true }
        @connections = {}  # Connection => true
        @users = {}        # user id => { Connection => true }
        @beat = nil
      end

      def add_connection(conn)
        @connections[conn] = true
        (@users[conn.user.id] ||= {}.compare_by_identity)[conn] = true
      end

      def remove_connection(conn)
        @connections.delete(conn)
        if (set = @users[conn.user.id])
          set.delete(conn)
          @users.delete(conn.user.id) if set.empty?
        end
      end

      def stream_from(stream, sub)
        (@streams[stream] ||= {}.compare_by_identity)[sub] = true
      end

      def stop_stream(stream, sub)
        if (set = @streams[stream])
          set.delete(sub)
          @streams.delete(stream) if set.empty?
        end
      end

      # One frame per distinct identifier (identifiers are interned when
      # subscribing, so equal identifiers are usually the same object).
      def broadcast(stream, message_json)
        subs = @streams[stream] or return 0
        last_id = nil
        frame = nil
        frames = nil
        dead = nil
        n = 0
        subs.each_key do |sub|
          id = sub.identifier_json
          unless id.equal?(last_id)
            if last_id.nil?
              frame = Frames.broadcast(id, message_json)
            else
              frames ||= { last_id => frame }
              frame = (frames[id] ||= Frames.broadcast(id, message_json))
            end
            last_id = id
          end
          conn = sub.connection
          (dead ||= []) << conn unless conn.enqueue(frame)
          n += 1
        end
        dead&.each(&:kill!)
        n
      end

      def disconnect_user(user_id, reconnect)
        set = @users[user_id] or return
        frame = reconnect ? Frames::REMOTE_RECONNECT : Frames::REMOTE
        set.keys.each { |conn| conn.close_with(frame) }
      end

      def start_beat(task)
        return if @beat
        @beat = task.async(transient: true) do
          loop do
            sleep BEAT_INTERVAL
            next if @connections.empty?
            frame = Frames.ping(Time.now.to_i)
            dead = nil
            @connections.each_key { |conn| (dead ||= []) << conn unless conn.enqueue(frame) }
            dead&.each(&:kill!)
          end
        end
      end
    end
  end
end
