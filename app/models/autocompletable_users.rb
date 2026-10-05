# frozen_string_literal: true

module Campfire
  # Autocompletable::UsersController#index: (User.all | room.users).active
  # (.filtered_by(query)).ordered, 20 per page (geared_pagination).
  module AutocompletableUsers
    PER_PAGE = 20
    COLS = "users.id, users.name, users.bio, users.updated_at"
    ROOM_JOIN = "INNER JOIN memberships ON users.id = memberships.user_id"

    ALL_SQL = "SELECT #{COLS} FROM users WHERE users.status = 0 ORDER BY LOWER(name) LIMIT ? OFFSET ?".freeze
    ALL_FILTERED_SQL = "SELECT #{COLS} FROM users WHERE users.status = 0 AND (name like ?) ORDER BY LOWER(name) LIMIT ? OFFSET ?".freeze
    ROOM_SQL = "SELECT #{COLS} FROM users #{ROOM_JOIN} WHERE memberships.room_id = ? AND users.status = 0 ORDER BY LOWER(name) LIMIT ? OFFSET ?".freeze
    ROOM_FILTERED_SQL = "SELECT #{COLS} FROM users #{ROOM_JOIN} WHERE memberships.room_id = ? AND users.status = 0 AND (name like ?) ORDER BY LOWER(name) LIMIT ? OFFSET ?".freeze

    COUNT_ALL_SQL = "SELECT COUNT(*) FROM users WHERE users.status = 0".freeze
    COUNT_ALL_FILTERED_SQL = "SELECT COUNT(*) FROM users WHERE users.status = 0 AND (name like ?)".freeze
    COUNT_ROOM_SQL = "SELECT COUNT(*) FROM users #{ROOM_JOIN} WHERE memberships.room_id = ? AND users.status = 0".freeze
    COUNT_ROOM_FILTERED_SQL = "SELECT COUNT(*) FROM users #{ROOM_JOIN} WHERE memberships.room_id = ? AND users.status = 0 AND (name like ?)".freeze

    Row = Struct.new(:id, :name, :bio, :updated_at)

    module_function

    # String#presence
    def presence(v) = v.is_a?(String) && !v.match?(/\A[[:space:]]*\z/) ? v : nil

    # geared_pagination's page param: positive integer, else 1.
    def page_number(param)
      n = param.to_s.to_i
      n < 1 ? 1 : n
    end

    # => [rows, total_count]
    def page(db, room_id, query, page)
      offset = (page - 1) * PER_PAGE
      like = query && "%#{query}%"
      rows = []
      push = ->(id, name, bio, upd) { rows << Row.new(id, name, bio, upd) }
      if room_id
        like ? db.query_splat(ROOM_FILTERED_SQL, room_id, like, PER_PAGE, offset, &push) : db.query_splat(ROOM_SQL, room_id, PER_PAGE, offset, &push)
      else
        like ? db.query_splat(ALL_FILTERED_SQL, like, PER_PAGE, offset, &push) : db.query_splat(ALL_SQL, PER_PAGE, offset, &push)
      end
      rows
    end

    def count(db, room_id, query)
      like = query && "%#{query}%"
      if room_id
        like ? db.query_single_splat(COUNT_ROOM_FILTERED_SQL, room_id, like) : db.query_single_splat(COUNT_ROOM_SQL, room_id)
      else
        like ? db.query_single_splat(COUNT_ALL_FILTERED_SQL, like) : db.query_single_splat(COUNT_ALL_SQL)
      end
    end
  end
end
