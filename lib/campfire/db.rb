# frozen_string_literal: true

require "extralite"
require_relative "writer"

module Campfire
  # One SQLite connection per Ractor. Extralite caches prepared statements by
  # SQL text, so callers pass literal (frozen) SQL strings and positional binds.
  # A connection that can hold one read transaction across a whole request.
  #
  # An autocommit read pays SQLite's read-transaction setup every statement
  # (WAL-index locks, fstat, cache validation): ~4.5us here, versus ~0.2us for
  # the same point query inside an open transaction. A page runs 5-30 queries.
  #
  # GET/HEAD requests run inside #read. The first write (#execute or
  # #transaction) commits the read transaction first, so writes stay
  # autocommit/IMMEDIATE: upgrading a stale read snapshot to a writer would
  # fail with SQLITE_BUSY_SNAPSHOT, and later reads must see the write.
  # Request handlers don't yield to other fibers between queries (no I/O until
  # the response is built), so sharing the Ractor's connection is safe; code
  # that does yield (Jobs.call) calls #end_read first.
  #
  # Lock waits happen in Ruby, not in SQLite's busy handler (busy_timeout is 0).
  # That handler sleeps inside a C call holding the Ractor's GVL, so the Ractor
  # never reaches a GC safepoint. A writer in another Ractor that stops for GC
  # then waits on the sleeper while still holding the write lock, and both sit
  # out the full timeout (5s stalls under concurrent posts). Kernel#sleep is a
  # safepoint, and under Async it yields to the Ractor's other fibers.
  class Connection < Extralite::Database
    BEGIN_SQL = "BEGIN"
    BEGIN_IMMEDIATE_SQL = "BEGIN IMMEDIATE"
    COMMIT_SQL = "COMMIT"
    ROLLBACK_SQL = "ROLLBACK"
    BUSY_TIMEOUT = 5.0
    alias_method :raw_execute, :execute

    def read
      return yield if transaction_active?
      busy_retry { raw_execute(BEGIN_SQL) }
      @reading = true
      begin
        yield
      ensure
        end_read
      end
    end

    def end_read
      return unless @reading
      @reading = false
      raw_execute(COMMIT_SQL) if transaction_active?
    end

    # Writes outside a transaction take the writer's permit (Writer) for their autocommit.
    def execute(...)
      end_read if @reading
      return super if transaction_active?
      Writer.hold { busy_retry { super } }
    end

    # Extralite's #transaction, holding the writer's permit (Writer). A nested transaction
    # joins the outer one, like ActiveRecord's (requires_new: false).
    def transaction(&)
      end_read if @reading
      return yield(self) if transaction_active?
      Writer.hold { write_transaction(&) }
    end

    private

    def write_transaction
      busy_retry { raw_execute(BEGIN_IMMEDIATE_SQL) }
      began = true
      yield self
    rescue => e
      abort = true
      raise unless e.is_a?(Rollback)
    ensure
      raw_execute(abort ? ROLLBACK_SQL : COMMIT_SQL) if began
    end

    def busy_retry
      pause = 0.0002
      begin
        yield
      rescue Extralite::BusyError
        deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + BUSY_TIMEOUT
        raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep pause
        pause *= 2 if pause < 0.005
        retry
      end
    end
  end

  # One SQLite connection per Ractor. Extralite caches prepared statements by
  # SQL text, so callers pass literal (frozen) SQL strings and positional binds.
  module DB
    # Rails 8 sqlite3 adapter defaults, plus temp_store and a larger cache.
    PRAGMAS = {
      journal_mode: "wal", synchronous: "normal", foreign_keys: "on",
      mmap_size: 134_217_728, journal_size_limit: 67_108_864, cache_size: -16_000,
      temp_store: "memory"
    }.freeze

    module_function

    def open(path)
      # legacy: skip Extralite's own WAL switch, which runs before busy_timeout
      # is set and fails with "database is locked" when workers open at once.
      db = Connection.new(path, legacy: true)
      db.busy_timeout = 5 # while opening only (see Connection)
      # Statements take microseconds; releasing the GVL per query costs ~150ns
      # and only helps other threads of the same Ractor.
      db.gvl_release_threshold = -1
      PRAGMAS.each { |k, v| db.raw_execute("PRAGMA #{k} = #{v}") }
      db.raw_execute("PRAGMA wal_autocheckpoint = 0") if background_checkpoints?
      # Long-lived connections: let SQLite gather stats where it lacks them. It may upgrade its
      # read to a write, which fails at once (no busy wait) while another connection writes;
      # the next connection will try again.
      begin
        db.raw_execute("PRAGMA optimize = 0x10002")
      rescue Extralite::BusyError
        nil
      end
      db.busy_timeout = 0
      db
    end

    def connection
      Ractor[:campfire_db] ||= open(Campfire.config.database_path)
    end

    def background_checkpoints? = defined?(Campfire::CONFIG) && Campfire.config.background_checkpoints

    # SQLite's auto-checkpoint runs inside the COMMIT that crosses 1000 WAL pages and fsyncs
    # the database there: every ~30th post took 10-20ms instead of 0.4ms. With
    # background_checkpoints the request connections never checkpoint; this thread (in the
    # main Ractor, which only waits on the workers) does. A PASSIVE checkpoint copies pages
    # without blocking anyone, but the WAL only starts over when a writer finds it fully copied,
    # which never happens under steady writes. So past RESTART_FRAMES it follows up with a
    # RESTART, holding the writer's permit (writers queue for the few pages written since),
    # and the next commit reuses the WAL from the start. Statements run
    # without the GVL (threshold >= 0), so neither the fsync nor the busy wait holds up a GC
    # barrier in the workers.
    CHECKPOINT_EVERY = 0.25  # seconds
    RESTART_FRAMES = 8192    # ~32MB of WAL
    PASSIVE_SQL = "PRAGMA wal_checkpoint(PASSIVE)"
    RESTART_SQL = "PRAGMA wal_checkpoint(RESTART)"

    def checkpointer(path)
      Thread.new do
        db = open(path)
        db.gvl_release_threshold = 1
        db.busy_timeout = 0.02
        loop do
          sleep CHECKPOINT_EVERY
          begin
            _busy, frames, = db.query_array(PASSIVE_SQL)[0]
            if frames > RESTART_FRAMES
              db.raw_execute(PASSIVE_SQL) # catch up on what arrived meanwhile, still unblocked
              Writer.hold { db.raw_execute(RESTART_SQL) } # writers queue instead of retrying
            end
          rescue Extralite::BusyError
            nil
          rescue => e
            Log.error("wal checkpoint", e)
          end
        end
      end
    end

    # db/triggers.sql: the Rails callbacks SQLite runs for us.
    def install_triggers(db) = db.execute(File.read(File.join(ROOT, "db", "triggers.sql")))

    # Creates the schema on an empty database (equivalent to db:schema:load).
    def prepare!(path)
      FileUtils.mkdir_p(File.dirname(path))
      db = open(path)
      unless db.query_single_splat("SELECT count(*) FROM sqlite_master WHERE name = 'accounts'").positive?
        # sqlite_sequence is internal; SQLite creates it with the first AUTOINCREMENT table.
        db.execute(File.read(File.join(ROOT, "db", "schema.sql")).sub(/^CREATE TABLE sqlite_sequence\b[^;]*;\n?/, ""))
      end
      install_triggers(db) # also on databases Rails made
      db.close
    end
  end

  # Rails stores UTC datetimes as "YYYY-MM-DD HH:MM:SS.ffffff". Views need ISO8601
  # and epoch milliseconds; derive both from the string without building Times.
  module Clock
    module_function

    def now_db = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")

    # "2026-03-02 16:00:00.123456" -> "2026-03-02T16:00:00Z"
    def iso8601(db)
      s = db.byteslice(0, 19)
      s.setbyte(10, 84) # "T"
      s << "Z"
    end

    def to_time(db)
      Time.utc(db[0, 4].to_i, db[5, 2].to_i, db[8, 2].to_i, db[11, 2].to_i, db[14, 2].to_i,
        db[17, 2].to_i, db.bytesize > 20 ? db[20, 6].ljust(6, "0").to_i : 0)
    end

    # Matches `(time.to_f * 1000).to_i`.
    def epoch_ms(db) = (to_time(db).to_f * 1000).to_i

    # Rails' to_fs(:number): "20260302160000"
    def number(db)
      s = +""
      s << db.byteslice(0, 4) << db.byteslice(5, 2) << db.byteslice(8, 2) <<
        db.byteslice(11, 2) << db.byteslice(14, 2) << db.byteslice(17, 2)
    end

    def from_time(t) = t.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
  end
end
