# frozen_string_literal: true

module Campfire
  # Recent searches (Search model) and full-text message search over the
  # message_search_index FTS5 table (Message::Searchable).
  class Search
    RECENT_LIMIT = 10
    RESULTS_LIMIT = 100
    NON_WORD = /[^[:word:]]/
    BLANK = /\A[[:space:]]*\z/

    RECENT_SQL = "SELECT query FROM searches WHERE user_id = ? ORDER BY updated_at DESC".freeze
    INSERT_SQL = "INSERT INTO searches (user_id, query, created_at, updated_at) VALUES (?, ?, ?, ?)".freeze
    TOUCH_SQL = "UPDATE searches SET updated_at = ? WHERE user_id = ? AND query = ?".freeze
    CLEAR_SQL = "DELETE FROM searches WHERE user_id = ?".freeze

    # Current.user.reachable_messages.search(q).last_page_of(100): the newest 100
    # matches (ORDER BY created_at DESC LIMIT 100), returned oldest first.
    MESSAGES_SQL = <<~SQL.tr("\n", " ").strip.freeze
      SELECT m.id, #{Message::VERSION} FROM messages m
      INNER JOIN rooms ON m.room_id = rooms.id
      INNER JOIN memberships ON rooms.id = memberships.room_id
      JOIN message_search_index idx ON m.id = idx.rowid
      WHERE memberships.user_id = ? AND idx.body MATCH ?
      ORDER BY m.created_at DESC LIMIT 100
    SQL

    class << self
      # SearchesController#query: params[:q]&.gsub(/[^[:word:]]/, " ").
      def sanitize(q)
        q&.gsub(NON_WORD, " ")
      end

      # String#present? for a sanitized query.
      def present?(q) = !q.nil? && !BLANK.match?(q)

      # Current.user.searches.ordered (queries only).
      def recent(db, user_id)
        db.query_splat(RECENT_SQL, user_id)
      end

      # Search.record: find_or_create_by(query:) (a create trims to the newest
      # 10), then touch.
      def record(db, user_id, query, now = Clock.now_db)
        # find_or_create_by(query:).touch; the insert trims to 10 (db/triggers.sql).
        db.transaction do
          db.execute(TOUCH_SQL, now, user_id, query)
          db.execute(INSERT_SQL, user_id, query, now, now) if db.changes.zero?
        end
      end

      def clear(db, user_id) = db.execute(CLEAR_SQL, user_id)

      # Message::Page (ids + cache versions, oldest first) of reachable
      # messages matching an already-sanitized, present query. The query goes
      # to MATCH verbatim like upstream, so FTS5 syntax errors (e.g. a lone
      # "NOT") raise just as they do in Rails.
      def messages(db, user_id, query)
        Message::Page.newest_first(db, MESSAGES_SQL, user_id, query)
      end
    end
  end
end
