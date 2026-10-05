# frozen_string_literal: true

# Writer: worker Ractors take the write permit in turn, so concurrent transactions never
# see SQLITE_BUSY, and a fiber waiting for the permit doesn't stop its Ractor's other fibers.
require "minitest/autorun"
require "tmpdir"
require "async"
require_relative "../lib/campfire"

class WriterTest < Minitest::Test
  def setup
    @path = File.join(Dir.mktmpdir("writer"), "w.sqlite3")
    db = Campfire::DB.open(@path)
    db.execute("CREATE TABLE counter (n INTEGER NOT NULL)")
    db.execute("INSERT INTO counter VALUES (0)")
    db.close
    Campfire::Writer.start unless Campfire::Writer.started?
  end

  # Read-modify-write in each transaction: lost updates or BUSY errors would show.
  def test_transactions_from_many_ractors_serialize
    workers = Array.new(4) do
      Ractor.new(@path) do |path|
        db = Campfire::DB.open(path)
        busy = 0
        200.times do
          db.transaction do
            n = db.query_single_splat("SELECT n FROM counter")
            db.execute("UPDATE counter SET n = ?", n + 1)
          end
        rescue Extralite::BusyError
          busy += 1
        end
        db.close
        busy
      end
    end
    assert_equal [0, 0, 0, 0], workers.map(&:value)
    db = Campfire::DB.open(@path)
    assert_equal 800, db.query_single_splat("SELECT n FROM counter")
  ensure
    db&.close
  end

  def test_waiting_suspends_only_the_fiber
    held = Ractor::Port.new
    holder = Ractor.new(@path, held) do |path, held|
      db = Campfire::DB.open(path)
      db.transaction { held.send(true); sleep 0.3 } # holds the permit
      db.close
      :done
    end
    held.receive
    worker = Ractor.new(@path) do |path|
      db = Campfire::DB.open(path)
      ticks = 0
      Sync do |task|
        writer = task.async { db.transaction { db.execute("UPDATE counter SET n = n + 1") } }
        ticker = task.async { loop { ticks += 1; sleep 0.01 } }
        writer.wait
        ticker.stop
      end
      db.close
      ticks
    end
    assert_operator worker.value, :>, 10, "the other fiber kept running while the writer waited"
    assert_equal :done, holder.value
  end
end
