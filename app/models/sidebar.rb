# frozen_string_literal: true

module Campfire
  # Data for Users::SidebarsController#show. Each query mirrors the SQL the
  # Rails reference issues (same joins, no extra ORDER BY tiebreakers), so
  # SQLite returns rows in the same order.
  module Sidebar
    DIRECT_PLACEHOLDERS = 20

    # One visible membership joined with its room: what the sidebar reads.
    # room_id_s is the id as text straight from SQL (nil when built elsewhere).
    Item = Struct.new(:membership_id, :membership_updated_at, :unread, :room_id, :room_name, :room_type, :room_updated_at, :room_id_s)

    # rooms.type comes back as a small integer so shared rows don't allocate a
    # type String; only direct rows read the updated_at columns (fragment
    # keys, sort order), so shared rows get NULL there.
    ROOM_TYPES = [Room::OPEN, Room::CLOSED, Room::DIRECT].freeze

    # Current.user.memberships.visible.with_ordered_room
    MEMBERSHIPS_SQL = <<~SQL.tr("\n", " ").strip.freeze
      SELECT memberships.id,
             CASE WHEN rooms.type = 'Rooms::Direct' THEN memberships.updated_at END,
             memberships.unread_at IS NOT NULL, rooms.id, CAST(rooms.id AS TEXT), rooms.name,
             CASE rooms.type WHEN 'Rooms::Open' THEN 0 WHEN 'Rooms::Closed' THEN 1 ELSE 2 END,
             CASE WHEN rooms.type = 'Rooms::Direct' THEN rooms.updated_at END
      FROM memberships INNER JOIN rooms ON rooms.id = memberships.room_id
      WHERE memberships.user_id = ? AND memberships.involvement != 'invisible'
      ORDER BY LOWER(rooms.name)
    SQL

    # membership.room.users.without(membership.user)
    MEMBERS_SQL = <<~SQL.tr("\n", " ").strip.freeze
      SELECT users.id, users.name, users.updated_at FROM users
      INNER JOIN memberships ON users.id = memberships.user_id
      WHERE memberships.room_id = ? AND users.id != ?
    SQL

    # Membership.where(room_id: Current.user.rooms.directs.pluck(:id)).pluck(:user_id).uniq.size
    DIRECT_USER_COUNT_SQL = <<~SQL.tr("\n", " ").strip.freeze
      SELECT COUNT(DISTINCT memberships.user_id) FROM memberships WHERE memberships.room_id IN
        (SELECT rooms.id FROM rooms INNER JOIN memberships ON rooms.id = memberships.room_id
         WHERE memberships.user_id = ? AND rooms.type = 'Rooms::Direct')
    SQL

    # User.active.where.not(id: exclude_user_ids).order(:created_at).limit(n)
    PLACEHOLDERS_SQL = <<~SQL.tr("\n", " ").strip.freeze
      SELECT users.id, users.name, users.updated_at FROM users
      WHERE users.status = 0 AND users.id != ? AND users.id NOT IN
        (SELECT memberships.user_id FROM memberships WHERE memberships.room_id IN
          (SELECT rooms.id FROM rooms INNER JOIN memberships ON rooms.id = memberships.room_id
           WHERE memberships.user_id = ? AND rooms.type = 'Rooms::Direct'))
      ORDER BY users.created_at LIMIT ?
    SQL

    module_function

    # => [directs (room updated_at desc), others (by LOWER(name))]
    def memberships(db, user_id)
      directs = []
      others = []
      db.query_splat(MEMBERSHIPS_SQL, user_id) do |mid, mupd, unread, rid, rid_s, rname, kind, rupd|
        item = Item.new(mid, mupd, unread == 1, rid, rname, ROOM_TYPES[kind], rupd, rid_s)
        (kind == 2 ? directs : others) << item
      end
      # sort_by { room.updated_at }.reverse; the DB format sorts lexically.
      directs.sort_by!(&:room_updated_at).reverse! if directs.size > 1
      [directs, others]
    end

    # Yields id, name, updated_at for each other member of a room.
    def each_member(db, room_id, user_id, &)
      db.query_splat(MEMBERS_SQL, room_id, user_id, &)
    end

    # Yields id, name, updated_at. `exclude_user_ids.count` upstream is the
    # distinct direct-room user ids plus Current.user.id appended (so the
    # current user counts twice once they're in any direct room).
    def each_placeholder_user(db, user_id, &)
      excluded = db.query_single_splat(DIRECT_USER_COUNT_SQL, user_id) + 1
      limit = DIRECT_PLACEHOLDERS - excluded
      limit = 0 if limit < 0
      return if limit == 0
      db.query_splat(PLACEHOLDERS_SQL, user_id, user_id, limit, &)
    end

    # to_sentence(two_words_connector: "+") of each member's initials
    # (first letters of up to three words, each capitalized).
    def initials_sentence(names)
      out = +""
      last = names.size - 1
      names.each_with_index do |name, i|
        if i > 0
          out << (last == 1 ? "+" : (i == last ? ", and " : ", "))
        end
        words = name.split(" ")
        n = words.size < 3 ? words.size : 3
        j = 0
        while j < n
          out << words[j][0].capitalize
          j += 1
        end
      end
      out
    end
  end
end
