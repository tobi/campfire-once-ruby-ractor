# frozen_string_literal: true

module Campfire
  # Background work (the Rails app's Active Job/Resque queues: push, webhook,
  # purge, ban, analyze/variant) runs in a small pool of job Ractors, so slow
  # HTTP calls and image processing never touch a request worker's reactor.
  #
  # A job is a frozen message `[kind, *args]` of integers/strings. Senders pick
  # a job Ractor round-robin and send to its port; each job Ractor runs an
  # Async reactor so I/O-bound jobs (webhooks, Web Push) overlap. Jobs that
  # need a result (an on-demand variant) carry a reply port.
  #
  # Like the Go and Rust ports, queues are in-process: a crash loses queued jobs.
  module Jobs
    MAX_INFLIGHT = 64
    HANDLERS = {} # kind => Module responding to .perform(*args); filled at boot

    module_function

    def register(kind, handler) = HANDLERS[kind] = handler

    def start(count, config)
      Ractor.make_shareable(HANDLERS)
      ports = Array.new(count) do |i|
        boot = Ractor::Port.new
        Ractor.new(boot, config, name: "jobs-#{i}") do |b, cfg|
          Campfire::Jobs.run(b, cfg)
        end
        boot.receive
      end
      const_set(:PORTS, Ractor.make_shareable(ports))
    end

    def started? = const_defined?(:PORTS)

    # Runs inside a job Ractor.
    def run(boot, config)
      Ractor[:config] = config
      inbox = Ractor::Port.new
      boot.send(inbox)
      queue = Thread::Queue.new
      Thread.new { loop { queue << inbox.receive } }
      Sync do |task|
        Log.attach(task)
        gate = Async::Semaphore.new(MAX_INFLIGHT, parent: task)
        while (job = queue.pop)
          gate.async { perform(job) }
        end
      end
    ensure
      DB.close
    end

    def perform(job)
      handler = HANDLERS.fetch(job[0])
      # A trailing reply port (Jobs.call) is not a handler argument.
      result = job.last.is_a?(Ractor::Port) ? handler.perform(*job[1...-1]) : handler.perform(*job[1..])
      job.last.send(result) if job.last.is_a?(Ractor::Port)
    rescue => e
      Log.error("job #{job[0]}", e)
      job.last.send(nil) if job.last.is_a?(Ractor::Port)
    end

    # Fire and forget. Falls back to inline execution (tests, single process).
    def later(kind, *args)
      job = Ractor.make_shareable([kind, *args])
      if started?
        n = (Ractor[:jobs_rr] = (Ractor[:jobs_rr] || 0) + 1)
        PORTS[n % PORTS.size].send(job)
      else
        perform(job)
      end
      nil
    end

    # Request/response over a reply port. Port#receive blocks the Ractor's
    # thread, so wait on a helper thread; Thread#value yields to the fiber
    # scheduler and other requests keep running meanwhile.
    def call(kind, *args)
      return HANDLERS.fetch(kind).perform(*args) unless started?
      Ractor[:campfire_db]&.end_read # we yield below; don't share a read txn
      reply = Ractor::Port.new
      later(kind, *args, reply)
      Thread.new { reply.receive }.value
    ensure
      reply&.close
    end
  end
end
