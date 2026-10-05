# frozen_string_literal: true

# Extralite 3.1.3 segfaults freeing a connection (Database#close or its GC
# finalizer; see jobs_test.rb). Connections are kept referenced for the whole
# run and the process leaves with exit! once Minitest's at_exit has set the
# status. Registered before minitest/autorun, so this at_exit runs after it.
at_exit { $stdout.flush; exit!($!.is_a?(SystemExit) ? $!.status : 1) }
require "minitest/autorun"
require "digest"
require_relative "../lib/campfire"
require_relative "../lib/campfire/storage"
require_relative "../app/models/models"
require_relative "../app/models/message"
require_relative "../app/models/room_ops"
require_relative "../app/models/search"
require_relative "../app/models/sidebar"
require_relative "../app/models/login"
require_relative "../app/models/autocompletable_users"
require_relative "../app/models/qr_code"

# Model logic behind sessions, search, the sidebar, autocomplete and QR codes,
# against a fresh in-memory database built from db/schema.sql.
class AuthSearchSidebarTest < Minitest::Test
  # schema.sql is a .schema dump; SQLite creates sqlite_sequence itself.
  OPEN_DBS = []
  SCHEMA = File.read(File.join(Campfire::ROOT, "db", "schema.sql")).sub(/^CREATE TABLE sqlite_sequence\(.*?\);\n/, "")

  def setup
    @db = Extralite::Database.new(":memory:")
    OPEN_DBS << @db
    @db.execute(SCHEMA)
    Campfire::DB.install_triggers(@db)
    Ractor[:rate_limit] = nil
  end

  # ---- Search ---------------------------------------------------------

  def test_sanitize_replaces_non_word_characters_like_upstream
    assert_nil Campfire::Search.sanitize(nil)
    assert_equal "coffee  tea ", Campfire::Search.sanitize("coffee, tea!")
    assert_equal "café 日本", Campfire::Search.sanitize("café 日本")
    assert_equal "a b", Campfire::Search.sanitize("a\"b")
  end

  def test_present_matches_string_present
    refute Campfire::Search.present?(nil)
    refute Campfire::Search.present?("")
    refute Campfire::Search.present?("  \t\n")
    assert Campfire::Search.present?(" x ")
  end

  def test_record_dedupes_touches_and_keeps_the_newest_ten
    user = create_user("Searcher", "s@example.com")
    12.times { |i| Campfire::Search.record(@db, user, "q#{i}", format("2026-01-01 00:00:%02d.000000", i)) }
    recent = Campfire::Search.recent(@db, user)
    assert_equal 10, recent.size
    assert_equal "q11", recent.first
    refute_includes recent, "q0"
    refute_includes recent, "q1"

    Campfire::Search.record(@db, user, "q5", "2026-01-01 00:01:00.000000")
    recent = Campfire::Search.recent(@db, user)
    assert_equal 10, recent.size, "re-recording an existing query must not insert"
    assert_equal "q5", recent.first

    Campfire::Search.clear(@db, user)
    assert_empty Campfire::Search.recent(@db, user)
  end

  def test_message_search_is_limited_to_reachable_rooms
    alice = create_user("Alice", "a@example.com")
    bob = create_user("Bob", "b@example.com")
    shared = create_room("Shared", Campfire::Room::OPEN, [alice, bob])
    secret = create_room("Secret", Campfire::Room::CLOSED, [bob])
    create_message(shared, bob, "coffee time", "2026-01-01 10:00:00.000000")
    create_message(secret, bob, "secret coffee", "2026-01-01 11:00:00.000000")
    create_message(shared, alice, "tea time", "2026-01-01 12:00:00.000000")

    assert_equal 1, Campfire::Search.messages(@db, alice, "coffee").size
    assert_equal 2, Campfire::Search.messages(@db, bob, "coffee").size
    assert_equal 0, Campfire::Search.messages(@db, alice, "zzz").size
  end

  # ---- Login ----------------------------------------------------------

  def test_authenticate
    id = Campfire::Login.create_user!(@db, "Dee", "dee@example.com", "secret123456")
    assert_equal id, Campfire::Login.authenticate(@db, "dee@example.com", "secret123456")
    assert_nil Campfire::Login.authenticate(@db, "dee@example.com", "wrong")
    assert_nil Campfire::Login.authenticate(@db, "DEE@example.com", "secret123456"), "emails match exactly"
    assert_nil Campfire::Login.authenticate(@db, "nobody@example.com", "secret123456")
    assert_nil Campfire::Login.authenticate(@db, "dee@example.com", "")
    assert_nil Campfire::Login.authenticate(@db, nil, "secret123456")

    @db.execute("UPDATE users SET status = 2 WHERE id = ?", id)
    assert_nil Campfire::Login.authenticate(@db, "dee@example.com", "secret123456"), "deactivated users can't sign in"
  end

  def test_create_user_grants_open_rooms_and_rejects_duplicates
    open_room = create_room("All Talk", Campfire::Room::OPEN, [])
    create_room("Closed", Campfire::Room::CLOSED, [])
    id = Campfire::Login.create_user!(@db, "Eve", "eve@example.com", "secret123456")
    assert_equal [open_room], @db.query_splat("SELECT room_id FROM memberships WHERE user_id = ?", id)
    assert_nil Campfire::Login.create_user!(@db, "Eve 2", "eve@example.com", "secret123456")
  end

  def test_rate_limit_is_a_fixed_window_of_ten
    10.times { refute Campfire::Login.rate_limited?("1.2.3.4", 1000) }
    assert Campfire::Login.rate_limited?("1.2.3.4", 1001)
    refute Campfire::Login.rate_limited?("5.6.7.8", 1001), "limits are per key"
    assert Campfire::Login.rate_limited?("1.2.3.4", 1179)
    refute Campfire::Login.rate_limited?("1.2.3.4", 1180), "a new window starts after 3 minutes"
  end

  def test_base58_tokens
    t = SecureRandom.base58(24)
    assert_equal 24, t.size
    assert_equal Encoding::UTF_8, t.encoding, "binary strings bind as SQLite BLOBs"
    assert_match(/\A[1-9A-HJ-NP-Za-km-z]+\z/, t)
  end

  # ---- Sidebar --------------------------------------------------------

  def test_memberships_split_and_order
    me = create_user("Me", "me@example.com")
    other = create_user("Other", "o@example.com")
    create_room("beta", Campfire::Room::OPEN, [me])
    create_room("Alpha", Campfire::Room::CLOSED, [me])
    old_dm = create_room(nil, Campfire::Room::DIRECT, [me, other], "2026-01-01 00:00:00.000000")
    new_dm = create_room(nil, Campfire::Room::DIRECT, [me], "2026-02-01 00:00:00.000000")
    hidden = create_room("Hidden", Campfire::Room::OPEN, [me])
    @db.execute("UPDATE memberships SET involvement = 'invisible' WHERE room_id = ?", hidden)

    directs, others = Campfire::Sidebar.memberships(@db, me)
    assert_equal [new_dm, old_dm], directs.map(&:room_id)
    assert_equal ["Alpha", "beta"], others.map(&:room_name)
    assert_equal [Campfire::Room::CLOSED, Campfire::Room::OPEN], others.map(&:room_type)
    assert_equal others.map { _1.room_id.to_s }, others.map(&:room_id_s)
    assert directs.all? { _1.membership_updated_at && _1.room_updated_at }
  end

  def test_placeholder_count_counts_current_user_twice_once_in_a_direct_room
    me = create_user("Me", "me@example.com")
    others = 25.times.map { |i| create_user("U#{i}", "u#{i}@example.com", format("2026-01-01 00:00:%02d.000000", i)) }
    ids = []
    Campfire::Sidebar.each_placeholder_user(@db, me) { |id, _, _| ids << id }
    assert_equal 19, ids.size # 20 - [me]
    assert_equal others.first(19), ids

    create_room(nil, Campfire::Room::DIRECT, [me, others[0]])
    ids = []
    Campfire::Sidebar.each_placeholder_user(@db, me) { |id, _, _| ids << id }
    assert_equal 17, ids.size # 20 - ({me, U0} + me)
    refute_includes ids, others[0]
  end

  def test_initials_sentence
    assert_equal "", Campfire::Sidebar.initials_sentence([])
    assert_equal "JD", Campfire::Sidebar.initials_sentence(["jason david"])
    assert_equal "AB+C", Campfire::Sidebar.initials_sentence(["Ann Bee", "cat"])
    assert_equal "ABC, D, and E", Campfire::Sidebar.initials_sentence(["a b c d", "d", "e"])
  end

  # ---- Autocomplete -----------------------------------------------------

  def test_autocomplete_params
    assert_nil Campfire::AutocompletableUsers.presence(nil)
    assert_nil Campfire::AutocompletableUsers.presence("  ")
    assert_equal "da", Campfire::AutocompletableUsers.presence("da")
    assert_equal 1, Campfire::AutocompletableUsers.page_number(nil)
    assert_equal 1, Campfire::AutocompletableUsers.page_number("0")
    assert_equal 1, Campfire::AutocompletableUsers.page_number("-3")
    assert_equal 1, Campfire::AutocompletableUsers.page_number("abc")
    assert_equal 3, Campfire::AutocompletableUsers.page_number("3")
  end

  # ---- QR code ----------------------------------------------------------

  # Digest of the Rails reference's GET /qr_code/aGVsbG8 ("hello").
  HELLO_SVG_SHA256 = "369e8f557b774bd00e782a3c398bd69bf66a34b5d9e667ddea49df8338f7f8c4"

  def test_qr_code_svg_matches_rqrcode
    svg = Campfire::QrCode.svg("hello")
    assert svg.start_with?('<?xml version="1.0" standalone="yes"?><svg version="1.1" xmlns="http://www.w3.org/2000/svg"')
    assert_includes svg, 'viewBox="0 0 231 231"' # version 1: 21 modules x 11
    assert_includes svg, '<rect width="231" height="231" x="0" y="0" fill="white"/><rect width="11" height="11" x="0" y="0" fill="black"/>'
    assert svg.end_with?("</svg>")
    assert_equal HELLO_SVG_SHA256, Digest::SHA256.hexdigest(svg)
  end

  def test_qr_code_works_in_a_ractor
    url = "http://127.0.0.1:3100/session/transfers/abc"
    assert_equal Campfire::QrCode.svg(url), Ractor.new(url) { |u| Campfire::QrCode.svg(u) }.value
  end

  private

  def create_user(name, email, created_at = "2026-01-01 00:00:00.000000")
    @db.execute("INSERT INTO users (name, email_address, role, status, created_at, updated_at) VALUES (?, ?, 0, 0, ?, ?)", name, email, created_at, created_at)
    @db.last_insert_rowid
  end

  def create_room(name, type, user_ids, updated_at = "2026-01-01 00:00:00.000000")
    @db.execute("INSERT INTO rooms (name, type, creator_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", name, type, user_ids.first || 0, updated_at, updated_at)
    id = @db.last_insert_rowid
    user_ids.each do |uid|
      @db.execute("INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at) VALUES (?, ?, 'mentions', ?, ?)", id, uid, updated_at, updated_at)
    end
    id
  end

  def create_message(room_id, user_id, text, at)
    @db.execute("INSERT INTO messages (room_id, creator_id, client_message_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", room_id, user_id, SecureRandom.uuid, at, at)
    id = @db.last_insert_rowid
    @db.execute("INSERT INTO message_search_index (rowid, body) VALUES (?, ?)", id, text)
    id
  end
end
