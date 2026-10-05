# frozen_string_literal: true

module Campfire
  # Cross-Ractor pub/sub. A hub Ractor fans each published message out to every
  # worker's port. Inside a worker, a plain thread blocks on the port and hands
  # messages to the fiber reactor through a Thread::Queue (fiber-scheduler aware).
  #
  # Messages are frozen arrays of frozen strings/integers, so they cross Ractor
  # boundaries without copying.
  module Bus
    module_function

    def start(_workers)
      hub = Ractor.new(name: "bus") do
        ports = []
        loop do
          msg = Ractor.receive
          case msg[0]
          when :register then ports << msg[1]
          when :publish
            ports.each do |p|
              p.send(msg[1])
            rescue Ractor::ClosedError
              ports.delete(p)
            end
          end
        end
      end
      const_set(:HUB, hub)
    end

    def started? = const_defined?(:HUB)

    def attach(task)
      inbox = Thread::Queue.new
      port = Ractor::Port.new
      HUB.send([:register, port].freeze)
      Thread.new { loop { inbox << port.receive } }
      task.async(transient: true) do
        while (msg = inbox.pop)
          begin
            deliver(msg)
          rescue => e
            Log.error("bus", e)
          end
        end
      end
    end

    # [:broadcast, stream, payload]  payload: HTML String or Hash, encoded per worker
    # [:cable, stream, json]         message already encoded (Cable.broadcast)
    # [:disconnect, user_id, reconnect] | [:invalidate, table]
    def publish(msg)
      msg = Ractor.make_shareable(msg)
      if started?
        HUB.send([:publish, msg].freeze)
      else
        deliver(msg)
      end
    end

    def deliver(msg)
      case msg[0]
      when :cable then Cable.local_broadcast_json(msg[1], msg[2])
      when :broadcast then Cable.local_broadcast(msg[1], msg[2])
      when :disconnect then Cable.local_disconnect(msg[1], msg[2])
      when :invalidate then Cache.invalidate(msg[1])
      end
    end
  end
end
