# frozen_string_literal: true

module Campfire
  # The single writer. SQLite allows one write transaction at a time; left to its file lock,
  # the worker Ractors raced for it (BEGIN IMMEDIATE, SQLITE_BUSY, sleep, retry) and some posts
  # lost for 100ms+ while others got straight in. Go has one write connection that queues
  # callers fairly; here the writer Ractor hands out the write permit in arrival order.
  #
  # Connection#transaction and #execute take the permit around their write, so callers don't
  # change. While a fiber waits, only that fiber is suspended: a pump thread in each Ractor
  # receives grants and wakes it through a Thread::Queue, which the fiber scheduler waits on.
  # Fibers of one Ractor queue on a local Mutex first, so each Ractor asks for at most one
  # permit at a time.
  #
  # The writes themselves still run on the caller's own connection. A transaction mixes SQL
  # with Ruby (last_insert_rowid, reads, branches), so shipping it to another Ractor would
  # cost a round trip per statement; passing the permit costs two messages per transaction.
  #
  # Without a writer (tests, CLI) #hold just yields, and SQLite's lock with
  # Connection#busy_retry still covers other processes.
  module Writer
    module_function

    def start
      boot = Ractor::Port.new
      Ractor.new(boot, name: "writer") { |b| Campfire::Writer.run(b) }
      const_set(:PORT, boot.receive)
    end

    def started? = const_defined?(:PORT)

    # The writer Ractor: [:acquire, port] queues port for the permit, [:release] passes it on.
    def run(boot)
      inbox = Ractor::Port.new
      boot.send(inbox)
      waiting = []
      held = false
      while (msg = inbox.receive)
        if msg.equal?(:release)
          (port = waiting.shift) ? port.send(true) : held = false
        elsif held
          waiting << msg
        else
          held = true
          msg.send(true)
        end
      end
    end

    # Runs the block holding the write permit.
    def hold
      return yield unless started?
      st = (Ractor[:writer] ||= State.new)
      st.mutex.synchronize do
        PORT.send(st.port)
        st.grants.pop
        begin
          yield
        ensure
          PORT.send(:release)
        end
      end
    end

    # Per Ractor: where grants arrive, and the thread that forwards them to the waiting fiber.
    class State
      attr_reader :mutex, :port, :grants

      def initialize
        @mutex = Thread::Mutex.new
        @port = Ractor::Port.new
        @grants = Thread::Queue.new
        port = @port
        grants = @grants
        Thread.new { loop { grants << port.receive } }
      end
    end
  end
end
