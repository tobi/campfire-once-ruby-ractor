# frozen_string_literal: true

module Campfire
  # Logging that costs the caller a String append and nothing else.
  #
  # Each Ractor appends lines to its own buffer (Ractor-local, so no locks).
  # A periodic task in that Ractor, or a full buffer, hands the whole buffer
  # to the log Ractor with `send(move: true)`: ownership moves, the bytes are
  # not copied, and the caller starts a fresh buffer. Only the log Ractor
  # touches fd 2; it timestamps each line and writes each batch in one call.
  #
  # Timestamps are taken on arrival (at most FLUSH_INTERVAL late) so workers
  # never format times. Messages already sitting in a buffer when the process
  # is killed with exit! are lost, as with any async logger.
  module Log
    FLUSH_INTERVAL = 0.1
    FLUSH_BYTES = 64 * 1024
    CAPACITY = 8 * 1024

    module_function

    def start
      port = Ractor::Port.new
      Ractor.new(port, name: "log") do |ready|
        inbox = Ractor::Port.new
        ready.send(inbox)
        Campfire::Log.drain(inbox)
      end
      const_set(:PORT, port.receive)
    end

    def started? = const_defined?(:PORT)

    # Runs in the log Ractor: the only writer of fd 2 once started.
    def drain(inbox)
      out = IO.for_fd(2, autoclose: false)
      out.sync = true
      batch = String.new(capacity: FLUSH_BYTES)
      loop do
        chunk = inbox.receive
        stamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ ")
        # bytesplice copies straight from the chunk: no per-line substring.
        pos = 0
        while (nl = chunk.byteindex("\n", pos))
          batch << stamp
          batch.bytesplice(batch.bytesize, 0, chunk, pos, nl - pos + 1)
          pos = nl + 1
        end
        out.write(batch)
        batch.clear
      end
    end

    def info(msg) = write(msg)

    def error(msg, exception = nil)
      if exception
        msg = "#{msg}: #{exception.class}: #{exception.message}"
        if (bt = exception.backtrace)
          bt.first(8).each { |l| msg << "\n    " << l }
        end
      end
      write(msg)
      flush # errors are rare and worth seeing promptly
    end

    def write(msg)
      unless started?
        $stderr.write(msg, "\n")
        return
      end
      buf = (Ractor[:log_buf] ||= String.new(capacity: CAPACITY))
      buf << prefix << msg << "\n"
      flush if buf.bytesize >= FLUSH_BYTES
      nil
    end

    def flush
      buf = Ractor[:log_buf]
      return if buf.nil? || buf.empty?
      Ractor[:log_buf] = String.new(capacity: CAPACITY)
      PORT.send(buf, move: true)
      nil
    end

    # Starts the periodic flush in the current Ractor's reactor.
    def attach(task)
      task.async(transient: true) do
        loop do
          sleep FLUSH_INTERVAL
          flush
        end
      end
    end

    def prefix
      Ractor[:log_prefix] ||= "[#{Ractor.current.name || "main"}] ".freeze
    end
  end
end
