# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "bundler/setup" # the patched, vendored extralite
require_relative "../lib/campfire/db"

class DBTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "t.sqlite3")
    @a = Campfire::DB.open(@path)
    @b = Campfire::DB.open(@path)
    @a.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT); CREATE VIRTUAL TABLE f USING fts5(v)")
    @a.execute("INSERT INTO t VALUES (1, 'a')")
  end

  def teardown
    @a.close
    @b.close
    FileUtils.rm_rf(@dir)
  end

  def test_pragmas
    assert_equal "wal", @a.query_single_splat("PRAGMA journal_mode")
    assert_equal 1, @a.query_single_splat("PRAGMA synchronous")
    assert_equal 1, @a.query_single_splat("PRAGMA foreign_keys")
    assert_equal 2, @a.query_single_splat("PRAGMA temp_store")
    assert_equal(-1, @a.gvl_release_threshold)
  end

  def test_read_holds_one_snapshot
    @a.read do
      assert @a.transaction_active?
      assert_equal "a", @a.query_single_splat("SELECT v FROM t WHERE id = 1")
      @b.execute("UPDATE t SET v = 'b' WHERE id = 1")
      assert_equal "a", @a.query_single_splat("SELECT v FROM t WHERE id = 1")
    end
    refute @a.transaction_active?
    assert_equal "b", @a.query_single_splat("SELECT v FROM t WHERE id = 1")
  end

  # Upgrading the stale snapshot would raise SQLITE_BUSY_SNAPSHOT; the write
  # must end the read transaction and later reads must see it.
  def test_write_after_concurrent_commit_ends_read
    @a.read do
      @a.query_single_splat("SELECT v FROM t WHERE id = 1")
      @b.execute("UPDATE t SET v = 'b' WHERE id = 1")
      @a.execute("UPDATE t SET v = v || 'c' WHERE id = 1")
      refute @a.transaction_active?
      assert_equal "bc", @a.query_single_splat("SELECT v FROM t WHERE id = 1")
      @a.transaction { @a.execute("INSERT INTO t VALUES (2, 'x')") }
    end
    assert_equal 2, @b.query_single_splat("SELECT count(*) FROM t")
  end

  def test_nested_read_and_exceptions
    @a.read do
      @a.read { assert @a.transaction_active? }
      assert @a.transaction_active?, "inner read must not end the outer one"
    end
    assert_raises(RuntimeError) { @a.read { raise "boom" } }
    refute @a.transaction_active?
  end

  def test_nested_transaction_joins_the_outer_one
    @a.transaction do
      @a.execute("INSERT INTO t VALUES (2, 'x')")
      assert_equal :inner, @a.transaction { @a.execute("INSERT INTO t VALUES (3, 'y')"); :inner }
      assert_equal 1, @b.query_single_splat("SELECT count(*) FROM t"), "inner must not commit"
    end
    assert_equal 3, @b.query_single_splat("SELECT count(*) FROM t")
    assert_raises(RuntimeError) { @a.transaction { @a.execute("INSERT INTO t VALUES (4, 'z')"); @a.transaction { raise "boom" } } }
    assert_equal 3, @b.query_single_splat("SELECT count(*) FROM t"), "an inner raise rolls back the whole transaction"
  end

  # Lock waits retry in Ruby (Kernel#sleep is a GC safepoint), not in SQLite's busy handler.
  def test_writer_waits_for_the_lock_in_ruby
    @b.raw_execute("BEGIN IMMEDIATE")
    t = Thread.new { sleep 0.05; @b.raw_execute("COMMIT") }
    assert_equal :ok, @a.transaction { @a.execute("INSERT INTO t VALUES (2, 'x')"); :ok }
    @a.execute("INSERT INTO t VALUES (3, 'y')")
    t.join
    assert_equal 3, @a.query_single_splat("SELECT count(*) FROM t")
    assert_nil @a.transaction { raise Extralite::Database::Rollback }
  end

  # Patched Extralite: a failing cached execute used to finalize the cached
  # stmt, so the next execute of the same SQL reset freed memory (segfault).
  def test_failed_execute_keeps_cached_stmt_valid
    sql = "INSERT INTO t VALUES (?, ?)"
    3.times { assert_raises(Extralite::Error) { @a.execute(sql, 1, "dup") } }
    @a.execute(sql, 3, "ok")
    assert_raises(Extralite::Error) { @a.execute(sql, 3, "dup") }
    @a.execute(sql, 4, "ok")
    assert_equal 3, @a.query_single_splat("SELECT count(*) FROM t")
  end

  # Patched Extralite: closing after FTS5 use used to double-finalize.
  def test_close_after_fts5
    db = Campfire::DB.open(File.join(@dir, "f.sqlite3"))
    db.execute("CREATE VIRTUAL TABLE f USING fts5(v); INSERT INTO f VALUES ('hello')")
    assert_equal 1, db.query_single_splat("SELECT count(*) FROM f WHERE f MATCH 'hello'")
    db.close
    assert db.closed?
  end
end
