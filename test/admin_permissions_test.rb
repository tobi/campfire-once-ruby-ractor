# frozen_string_literal: true

# Permission rules for the administration and room-management controllers
# (upstream ensure_can_administer / room_scope / ensure_permission_to_create_rooms).
require "minitest"
require_relative "support/app_harness"

AppHarness.boot!

class AdminPermissionsTest < Minitest::Test
  DAVID = AppHarness::DAVID   # administrator
  KEVIN = 712064548           # member
  LOU = 773523958             # member, not in Kevin's direct room
  ALL_TALK = 486777696        # closed, created by David, Kevin is not a member
  DESIGNERS = 654632876       # closed, created by David, Kevin is a member
  QUIET = 699448326           # closed, created by Kevin
  KEVINS_DIRECT = 340026324   # direct: Kevin + Bender Bot
  DAVIDS_DIRECT = 186869642   # direct: David + Jason

  # A client signed in as `user_id` through a fresh session row.
  class As < AppHarness::Client
    def initialize(user_id)
      super()
      token = SecureRandom.alphanumeric(24)
      now = Campfire::Clock.now_db
      AppHarness.db.execute("INSERT INTO sessions (user_id, token, last_active_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", user_id, token, now, now, now)
      @cookies["session_token"] = Campfire::RailsCompat.escape_cookie(Campfire::Cache.signed_session_token(token))
    end
  end

  def db = AppHarness.db
  def user(id) = Campfire::User.find(db, id)
  def room(id) = Campfire::Room.find(db, id)
  def admin = (@admin ||= As.new(DAVID))
  def member = (@member ||= As.new(KEVIN))

  def setup
    AppHarness.captured.clear
  end

  def test_can_administer_rules
    david, kevin = user(DAVID), user(KEVIN)
    assert david.can_administer?
    assert david.can_administer?(room(QUIET)), "administrators administer every room"
    refute kevin.can_administer?
    refute kevin.can_administer?(room(DESIGNERS))
    assert kevin.can_administer?(room(QUIET)), "creators administer their rooms"
  end

  def test_account_admin_endpoints_forbid_members
    assert_equal 403, member.form("POST", "/account", "_method" => "patch", "account[name]" => "Hijacked").status
    assert_equal 403, member.form("POST", "/account/join_code", {}).status
    assert_equal 403, member.form("POST", "/account/logo", "_method" => "delete").status
    assert_equal 403, member.get("/account/custom_styles/edit").status
    assert_equal 403, member.form("POST", "/account/custom_styles", "_method" => "patch", "account[custom_styles]" => "x").status
    assert_equal 403, member.get("/account/bots").status
    assert_equal 403, member.form("POST", "/account/bots", "user[name]" => "Evil").status
    assert_equal 403, member.form("POST", "/account/bots/394959859/key", "_method" => "put").status
    assert_equal 403, member.form("POST", "/account/users/#{LOU}", "_method" => "patch", "user[role]" => "administrator").status
    assert_equal 403, member.form("POST", "/account/users/#{LOU}", "_method" => "delete").status
    assert_equal 403, member.form("POST", "/users/#{LOU}/ban", {}).status
    refute_equal "Hijacked", Campfire::Account.first(db).name
    assert_equal 0, user(LOU).role
    assert_equal 0, user(LOU).status
  end

  def test_members_may_view_account_settings_but_not_admin_controls
    r = member.get("/account/edit")
    assert_equal 200, r.status
    refute_includes r.body, %(action="/account/join_code")
    assert_equal 200, member.get("/account/logo").status
  end

  def test_admin_can_change_roles_and_ban
    r = admin.form("POST", "/account/users/#{LOU}", "_method" => "patch", "user[role]" => "administrator")
    assert_equal [302, "http://#{AppHarness::HOST}/account/edit"], [r.status, r.headers["location"]]
    assert user(LOU).administrator?
    admin.form("POST", "/account/users/#{LOU}", "_method" => "patch", "user[role]" => "member")
    refute user(LOU).administrator?

    assert_equal 302, admin.form("POST", "/users/#{LOU}/ban", {}).status
    assert user(LOU).banned?
    assert_equal 302, admin.form("POST", "/users/#{LOU}/ban", "_method" => "delete").status
    assert user(LOU).active?
  end

  def test_room_update_requires_administering_the_room
    r = member.form("POST", "/rooms/closeds/#{DESIGNERS}", "_method" => "patch", "room[name]" => "Mine now")
    assert_equal 403, r.status
    assert_equal "Designers", room(DESIGNERS).name

    r = member.form("POST", "/rooms/closeds/#{QUIET}", "_method" => "patch", "room[name]" => "Quieter", "user_ids[]" => KEVIN.to_s)
    assert_equal 302, r.status
    assert_equal "Quieter", room(QUIET).name
  ensure
    db.execute("UPDATE rooms SET name = 'Quiet Corner' WHERE id = ?", QUIET)
  end

  def test_non_administrators_see_a_read_only_room_form
    r = member.get("/rooms/closeds/#{DESIGNERS}/edit")
    assert_equal 200, r.status
    assert_includes r.body, %(<h1 class="flex-item-grow txt-x-large">\n        Designers\n      </h1>)
    refute_includes r.body, %(name="room[name]")
    refute_includes r.body, "Delete Designers"
    refute_includes r.body, %(name="user_ids[]")

    r = member.get("/rooms/closeds/#{QUIET}/edit")
    assert_includes r.body, %(name="room[name]")
    assert_includes r.body, "Delete Quiet Corner"
  end

  def test_room_scope_hides_rooms_the_user_is_not_in_and_keeps_types_apart
    home = "http://#{AppHarness::HOST}/"
    r = member.get("/rooms/closeds/#{ALL_TALK}/edit")
    assert_equal [302, home], [r.status, r.headers["location"]]
    # Directs are out of reach of the open/closed controllers and vice versa.
    assert_equal home, member.get("/rooms/opens/#{KEVINS_DIRECT}/edit").headers["location"]
    r = member.form("POST", "/rooms/closeds/#{KEVINS_DIRECT}", "_method" => "patch", "room[name]" => "x")
    assert_equal [302, home], [r.status, r.headers["location"]]
    assert_equal Campfire::Room::DIRECT, room(KEVINS_DIRECT).type
    assert_equal home, member.get("/rooms/directs/#{DESIGNERS}/edit").headers["location"]
    assert_equal home, member.get("/rooms/directs/#{DAVIDS_DIRECT}/edit").headers["location"]
  end

  # Deliberate divergence: Rails answers 500 (no rooms/directs/show template).
  def test_direct_room_show_redirects_to_the_room_page
    r = member.get("/rooms/directs/#{KEVINS_DIRECT}")
    assert_equal [302, "http://#{AppHarness::HOST}/rooms/#{KEVINS_DIRECT}"], [r.status, r.headers["location"]]
    assert_equal 404, member.get("/rooms/directs/nope").status
  end

  def test_room_destroy_requires_administering_the_room
    assert_equal 403, member.form("POST", "/rooms/#{DESIGNERS}", "_method" => "delete").status
    assert room(DESIGNERS)
  end

  def test_any_direct_member_may_delete_it
    id = Campfire::RoomOps.create!(db, Campfire::Room::DIRECT, nil, DAVID, [DAVID, KEVIN]).id
    r = member.form("POST", "/rooms/directs/#{id}", "_method" => "delete")
    assert_equal [302, "http://#{AppHarness::HOST}/"], [r.status, r.headers["location"]]
    assert_nil room(id)
    assert(AppHarness.captured.any? { |e| e[0] == :broadcast && e[1] == "rooms" && e[2].include?(%(action="remove" target="list_rooms_direct_#{id}")) })
  end

  def test_room_creation_can_be_restricted_to_administrators
    assert_equal 200, member.get("/rooms/opens/new").status
    admin.form("POST", "/account", "_method" => "patch", "account[settings][restrict_room_creation_to_administrators]" => "true")
    assert Campfire::Account.first(db).restrict_room_creation_to_administrators?
    assert_equal 403, member.get("/rooms/opens/new").status
    assert_equal 403, member.get("/rooms/closeds/new").status
    assert_equal 403, member.form("POST", "/rooms/opens", "room[name]" => "Nope").status
    assert_equal 403, member.form("POST", "/rooms/closeds", "room[name]" => "Nope").status
    assert_equal 200, admin.get("/rooms/opens/new").status
    # Directs are never restricted.
    assert_equal 200, member.get("/rooms/directs/new").status
  ensure
    admin.form("POST", "/account", "_method" => "patch", "account[settings][restrict_room_creation_to_administrators]" => "false")
  end

  def test_open_room_created_by_conversion_grants_everyone
    id = Campfire::RoomOps.create!(db, Campfire::Room::CLOSED, "Convert me", KEVIN, [KEVIN]).id
    r = member.form("POST", "/rooms/opens/#{id}", "_method" => "patch", "room[name]" => "Converted")
    assert_equal 302, r.status
    assert_equal Campfire::Room::OPEN, room(id).type
    active = db.query_splat("SELECT id FROM users WHERE status = 0").sort
    assert_equal active, room(id).user_ids(db).sort
    assert(AppHarness.captured.any? { |e| e[0] == :broadcast && e[1] == "rooms" && e[2].include?(%(action="replace" target="list_rooms_open_#{id}")) })
  end

  def test_closed_room_grants_and_revokes_from_user_ids
    id = Campfire::RoomOps.create!(db, Campfire::Room::CLOSED, "Club", DAVID, [DAVID, KEVIN]).id
    r = admin.form("POST", "/rooms/closeds/#{id}", "_method" => "patch", "room[name]" => "Club", "user_ids[]" => [DAVID.to_s, LOU.to_s, "999999"])
    assert_equal 302, r.status
    assert_equal [DAVID, LOU].sort, room(id).user_ids(db).sort
  end

  def test_profile_is_always_the_current_user
    r = member.get("/users/#{DAVID}/profile")
    assert_equal 200, r.status
    assert_includes r.body, %(view-transition-name: avatar-#{KEVIN})
    member.form("POST", "/users/#{DAVID}/profile", "_method" => "patch", "user[bio]" => "Kevin's bio")
    assert_equal "Kevin's bio", user(KEVIN).bio
    refute_equal "Kevin's bio", user(DAVID).bio
  ensure
    db.execute("UPDATE users SET bio = NULL WHERE id = ?", KEVIN)
  end
end

# Extralite (SQLite 3.53.4) segfaults when a connection that wrote to the FTS5
# message_search_index is closed or finalized, which RoomOps.destroy! does.
# Run the suite explicitly and skip interpreter teardown.
code = Minitest.run(ARGV) ? 0 : 1
$stdout.flush
$stderr.flush
Process.exit!(code)
