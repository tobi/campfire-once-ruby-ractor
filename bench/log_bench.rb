# frozen_string_literal: true
# Cost of Log.info on the caller's side, inside a worker-like Ractor.
require "async"
require_relative "../lib/campfire/log"

Campfire::Log.start
r = Ractor.new(name: "bench") do
  Sync do |task|
    Campfire::Log.attach(task)
    n = 1_000_000
    msg = "GET /rooms/486777696 200"
    Campfire::Log.info(msg) # warm
    a0 = GC.stat(:total_allocated_objects)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    n.times { Campfire::Log.info(msg) }
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    allocs = GC.stat(:total_allocated_objects) - a0
    [t / n * 1e9, allocs.fdiv(n)]
  end
end
ns, allocs = r.value
sleep 0.5
STDOUT.puts format("Log.info: %.0f ns/call, %.3f allocs/call (flush every 64KB moves the buffer)", ns, allocs)
