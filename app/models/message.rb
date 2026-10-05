# frozen_string_literal: true

require_relative "models"

module Campfire
  class Room
    DOM_PREFIXES = { OPEN => "rooms_open", CLOSED => "rooms_closed", DIRECT => "rooms_direct" }.freeze

    # id.to_s, once per row (rendered several times per page).
    def id_s = (@id_s ||= id.to_s.freeze)

    # dom_id(room): "rooms_closed_486777696"
    def dom_key = (@dom_key ||= "#{DOM_PREFIXES.fetch(type)}_#{id}")

    # GlobalID#to_param, the streamable part of Turbo stream names.
    def gid_param = (@gid_param ||= RailsCompat::GID.build(type, id).to_param)

    def member_user_ids(db) = db.query_splat("SELECT user_id FROM memberships WHERE room_id = ?".freeze, id)

    # @room.direct? ? @room.users.active_bots : @message.mentionees.active_bots,
    # minus the creator, keeping bots with a webhook (deliver_webhook_later).
    def webhook_bot_ids(db, creator_id, mentioned_ids)
      if direct?
        db.query_splat("SELECT u.id FROM users u JOIN memberships m ON m.user_id = u.id JOIN webhooks w ON w.user_id = u.id " \
          "WHERE m.room_id = ? AND u.role = 2 AND u.status = 0 AND u.id != ? ORDER BY u.id".freeze, id, creator_id)
      elsif mentioned_ids.nil? || mentioned_ids.empty?
        []
      else
        db.query_splat("SELECT u.id FROM users u JOIN memberships m ON m.user_id = u.id JOIN webhooks w ON w.user_id = u.id " \
          "WHERE m.room_id = ? AND u.role = 2 AND u.status = 0 AND u.id != ? AND u.id IN (SELECT value FROM json_each(?)) ORDER BY u.id".freeze,
          id, creator_id, JSON.generate(mentioned_ids))
      end
    end

    # Room.original.id (the oldest room).
    def self.original_id(db)
      db.query_single_splat("SELECT id FROM rooms ORDER BY created_at LIMIT 1".freeze)
    end

    def self.original(db)
      row = db.query_single_array("SELECT #{COLS} FROM rooms ORDER BY created_at LIMIT 1".freeze)
      row && new(*row)
    end
  end

  # A message row. The first six fields come from `messages`; the rest are
  # filled by Message.load_presentation (users, rich text, attachment) for
  # rendering. Pages (Message::Page) carry only ids and cache versions so the
  # hot path (every fragment cached) is one small query.
  class Message < Struct.new(:id, :client_message_id, :created_at, :updated_at, :creator_id, :room_id,
    :creator_name, :creator_bio, :creator_updated_at, :body, :attachment, :boosts)
    PAGE_SIZE = 40
    COLS = "m.id, m.client_message_id, m.created_at, m.updated_at, m.creator_id, m.room_id"

    # Cache version: updated_at as integer microseconds since the epoch (no
    # String allocation per row). Message.version(str) computes the same in Ruby.
    VERSION = "(unixepoch(m.updated_at) * 1000000 + CAST(substr(m.updated_at || '.000000', 21, 6) AS INTEGER))"

    PRESENTATION = <<~SQL.freeze
      SELECT #{COLS}, u.name, u.bio, u.updated_at, r.body,
        #{Storage::COLUMNS}
      FROM messages m
      LEFT JOIN users u ON u.id = m.creator_id -- a missing creator renders messages/_unrenderable
      LEFT JOIN action_text_rich_texts r ON r.record_type = 'Message' AND r.record_id = m.id AND r.name = 'body'
      LEFT JOIN active_storage_attachments a ON a.record_type = 'Message' AND a.record_id = m.id AND a.name = 'attachment'
      LEFT JOIN active_storage_blobs b ON b.id = a.blob_id
      WHERE m.id IN (SELECT value FROM json_each(?))
    SQL

    BOOSTS = <<~SQL.freeze
      SELECT bo.id, bo.message_id, bo.booster_id, bo.content, bu.name, bu.bio, bu.updated_at, bo.updated_at
      FROM boosts bo JOIN users bu ON bu.id = bo.booster_id
      WHERE bo.message_id IN (SELECT value FROM json_each(?))
      ORDER BY bo.created_at
    SQL

    # Ordered ids + cache versions of a page of messages (ascending created_at).
    class Page
      attr_reader :ids, :versions

      def initialize(ids = [], versions = [])
        @ids = ids
        @versions = versions
      end

      def size = @ids.size
      def empty? = @ids.empty?
      def any? = !@ids.empty?
      def first_id = @ids.first
      def last_id = @ids.last

      def concat(other)
        @ids.concat(other.ids)
        @versions.concat(other.versions)
        self
      end

      # Collects rows yielded newest-first and flips them in place.
      def self.newest_first(db, sql, *binds)
        page = new
        ids = page.ids
        versions = page.versions
        db.query_splat(sql, *binds) do |id, version|
          ids << id
          versions << version
        end
        ids.reverse!
        versions.reverse!
        page
      end

      def self.oldest_first(db, sql, *binds)
        page = new
        ids = page.ids
        versions = page.versions
        db.query_splat(sql, *binds) do |id, version|
          ids << id
          versions << version
        end
        page
      end
    end

    Blob = Storage::Blob

    Boost = Struct.new(:id, :message_id, :booster_id, :content, :booster_name, :booster_bio, :booster_updated_at, :updated_at)

    class << self
      def version(updated_at)
        t = Clock.to_time(updated_at)
        t.to_i * 1_000_000 + t.usec
      end

      # Rails binds Times as "YYYY-MM-DD HH:MM:SS" plus ".uuuuuu" only when
      # usec > 0; string comparison in SQLite depends on that exact shape.
      def time_bind(db_time)
        db_time.end_with?(".000000") ? db_time.byteslice(0, 19) : db_time
      end

      def time_bind_from_time(t)
        s = t.strftime("%Y-%m-%d %H:%M:%S")
        s << format(".%06d", t.usec) if t.usec > 0
        s
      end

      def time_bind_from_ms(ms)
        sec, msec = ms.divmod(1000)
        t = Time.at(sec).utc
        s = t.strftime("%Y-%m-%d %H:%M:%S")
        s << format(".%06d", msec * 1000) if msec > 0
        s
      end

      # ---- pages (Message::Pagination) ---------------------------------

      def last_page(db, room_id)
        Page.newest_first(db, "SELECT m.id, #{VERSION} FROM messages m WHERE m.room_id = ? ORDER BY m.created_at DESC LIMIT #{PAGE_SIZE}".freeze, room_id)
      end

      def page_before(db, room_id, created_at)
        Page.newest_first(db, "SELECT m.id, #{VERSION} FROM messages m WHERE m.room_id = ? AND m.created_at < ? ORDER BY m.created_at DESC LIMIT #{PAGE_SIZE}".freeze, room_id, time_bind(created_at))
      end

      def page_after(db, room_id, created_at)
        Page.oldest_first(db, "SELECT m.id, #{VERSION} FROM messages m WHERE m.room_id = ? AND m.created_at > ? ORDER BY m.created_at ASC LIMIT #{PAGE_SIZE}".freeze, room_id, time_bind(created_at))
      end

      def page_around(db, message)
        page = page_before(db, message.room_id, message.created_at)
        page.ids << message.id
        page.versions << version(message.updated_at)
        page.concat(page_after(db, message.room_id, message.created_at))
      end

      # Rooms::RefreshesController: created since / updated since (minus the new ones).
      def page_created_since(db, room_id, since_bind)
        Page.oldest_first(db, "SELECT m.id, #{VERSION} FROM messages m WHERE m.room_id = ? AND m.created_at > ? ORDER BY m.created_at ASC LIMIT #{PAGE_SIZE}".freeze, room_id, since_bind)
      end

      def page_updated_since(db, room_id, since_bind, without_ids)
        Page.newest_first(db, "SELECT m.id, #{VERSION} FROM messages m WHERE m.room_id = ? AND m.id NOT IN (SELECT value FROM json_each(?)) AND m.updated_at > ? ORDER BY m.created_at DESC LIMIT #{PAGE_SIZE}".freeze,
          room_id, JSON.generate(without_ids), since_bind)
      end

      def paged?(db, room_id)
        db.query_single_splat("SELECT count(*) FROM messages WHERE room_id = ?".freeze, room_id) > PAGE_SIZE
      end

      # ---- lookups ------------------------------------------------------

      def find_in_room(db, room_id, id)
        row = db.query_single_array("SELECT #{COLS} FROM messages m WHERE m.room_id = ? AND m.id = ?".freeze, room_id, id.to_i)
        row && new(*row)
      end

      # Current.user.reachable_messages.find(id)
      def find_reachable(db, user_id, id)
        row = db.query_single_array("SELECT #{COLS} FROM messages m JOIN memberships ms ON ms.room_id = m.room_id WHERE ms.user_id = ? AND m.id = ?".freeze, user_id, id.to_i)
        row && new(*row)
      end

      # Full presentation rows for `ids` (with_presentation): one query for
      # messages+creators+bodies+attachments, one for boosts+boosters.
      # Returns { id => Message }.
      def load_presentation(db, ids)
        json = JSON.generate(ids)
        out = {}
        db.query_array(PRESENTATION, json).each do |r|
          m = new(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9],
            r[10] && Storage::Blob.new(r[10], r[11], r[12], r[13], r[14], r[15], r[16], r[17], r[18]), nil)
          out[m.id] = m
        end
        db.query_array(BOOSTS, json).each do |r|
          if (m = out[r[1]])
            (m.boosts ||= []) << Boost.new(*r)
          end
        end
        out
      end

      def load_one(db, id) = load_presentation(db, [id])[id]

      # ---- rich text attachables ------------------------------------------

      # RichText resolver: user id -> RichText::User (memoized per call site).
      def user_resolver(db)
        memo = {}
        lambda do |id|
          id = id.to_i
          memo.fetch(id) do
            row = db.query_single_array("SELECT id, name, bio, updated_at FROM users WHERE id = ?".freeze, id)
            memo[id] = row && rich_text_user(*row)
          end
        end
      end

      def rich_text_user(id, name, bio, updated_at)
        title = bio.nil? || bio.strip.empty? ? name : "#{name} – #{bio}"
        avatar = "/users/#{Helpers.avatar_token(id)}/avatar?v=#{Clock.number(updated_at)}"
        RichText::User.new(id, name, title, Campfire.secrets.attachable_sgid("User", id), "/users/#{id}", avatar)
      end

      # ---- writes -------------------------------------------------------

      # room.messages.create!(body:, attachment:, client_message_id:, creator:)
      # plus touch: true on the room and the search index (Searchable).
      # `body` is the stored (canonical) rich text HTML or nil (attachment-only
      # messages have no rich text row); `plain_text` is its to_plain_text.
      # Returns the Message with presentation fields filled.
      def create!(db, room, creator, body:, plain_text: nil, blob: nil, client_message_id: nil, now: Clock.now_db)
        client_message_id = SecureRandom.uuid if client_message_id.nil? || client_message_id.empty?
        id = message = nil
        db.transaction do
          db.execute("INSERT INTO messages (client_message_id, created_at, updated_at, creator_id, room_id) VALUES (?, ?, ?, ?, ?)".freeze,
            client_message_id, now, now, creator.id, room.id)
          id = db.last_insert_rowid
          unless body.nil?
            db.execute("INSERT INTO action_text_rich_texts (body, created_at, name, record_id, record_type, updated_at) VALUES (?, ?, 'body', ?, 'Message', ?)".freeze,
              body, now, id, now)
          end
          room.updated_at = now # the insert touches the room and marks it unread (db/triggers.sql)
          Storage.attach(db, blob.id, "Message", id, "attachment", analyze: false) if blob
          message = new(id, client_message_id, now, now, creator.id, room.id, creator.name, creator.bio, creator.updated_at, body, blob, nil)
          message.instance_variable_set(:@plain_text_body, plain_text) if plain_text && !plain_text.strip.empty?
          # One commit for the whole post; a failed index insert only undoes itself.
          index!(db, message)
        end
        message
      end

      def index!(db, message)
        db.execute("INSERT INTO message_search_index(rowid, body) VALUES (?, ?)".freeze, message.id, message.plain_text_body)
      rescue Extralite::Error => e
        Log.error("search index", e)
      end
    end

    def dom_key = client_message_id

    # message.boosts.create!(content:, booster:): touches the message (and,
    # through it, the room). Returns the Message::Boost for rendering.
    def create_boost!(db, booster, content, now: Clock.now_db)
      bid = nil
      db.transaction do
        db.execute("INSERT INTO boosts (booster_id, content, created_at, message_id, updated_at) VALUES (?, ?, ?, ?, ?)".freeze,
          booster.id, content, now, id, now)
        bid = db.last_insert_rowid
      end
      self.updated_at = now # the insert touched the message and its room (db/triggers.sql)
      Boost.new(bid, id, booster.id, content, booster.name, booster.bio, booster.updated_at, now)
    end

    # message.boosts.find_by!(id:, booster:).destroy!; nil when not found.
    def destroy_boost!(db, boost_id, booster_id, now: Clock.now_db)
      deleted = false
      db.transaction do
        db.execute("DELETE FROM boosts WHERE id = ? AND message_id = ? AND booster_id = ?".freeze, boost_id.to_i, id, booster_id)
        deleted = db.changes.positive?
        touch!(db, now) if deleted
      end
      deleted ? boost_id.to_i : nil
    end

    def touch!(db, now = Clock.now_db)
      db.execute("UPDATE messages SET updated_at = ? WHERE id = ?".freeze, now, id) # and the room
      self.updated_at = now
    end

    # Rendering context for the rich text body (request host + mention
    # resolver); set before plain_text_body / presentation on render paths.
    def context!(host, resolver)
      @host = host
      @resolver = resolver
      self
    end

    def body_render
      @body_render ||= body ? RichText.render(body, host: @host, resolver: @resolver) : nil
    end

    def presentation(host = @host, resolver = @resolver)
      return @presentation if @presentation
      body ? RichText.presentation(body, host: host, resolver: resolver) : ""
    end

    # Reuse one RichText.render result (message creation) for the first render.
    def rendered!(result)
      @presentation = result.presentation
      @plain_text_body = result.plain_text unless result.plain_text.nil? || result.plain_text.strip.empty?
      self
    end

    # body.to_plain_text.presence || attachment&.filename || ""
    def plain_text_body
      @plain_text_body ||= begin
        text = body ? RichText.plain_text(body, host: @host, resolver: @resolver) : nil
        if text.nil? || text.strip.empty?
          attachment&.filename || ""
        else
          text
        end
      end
    rescue RichText::Error
      @unrenderable = true
      @plain_text_body = attachment&.filename || ""
    end

    # message_tag raised (body.to_plain_text failed): upstream renders
    # messages/_unrenderable in place of the message.
    # A message whose creator row is gone (users.name is NOT NULL) raises too.
    def unrenderable?
      return true if creator_name.nil?
      plain_text_body
      @unrenderable == true
    end

    def all_emoji? = RichText.all_emoji?(plain_text_body)

    def sound
      return nil if attachment
      text = plain_text_body
      return nil unless text.start_with?("/play ")
      (m = %r{\A/play (\w+)\z}.match(text)) && Sound.find_by_name(m[1])
    end

    def content_type
      if attachment then "attachment"
      elsif sound then "sound"
      else "text"
      end
    end

    def update_body!(db, body, now: Clock.now_db)
      db.transaction do
        db.execute("UPDATE action_text_rich_texts SET body = ?, updated_at = ? WHERE record_type = 'Message' AND record_id = ? AND name = 'body'".freeze, body, now, id)
        if db.changes.zero?
          db.execute("INSERT INTO action_text_rich_texts (body, created_at, name, record_id, record_type, updated_at) VALUES (?, ?, 'body', ?, 'Message', ?)".freeze, body, now, id, now)
        end
        db.execute("UPDATE messages SET updated_at = ? WHERE id = ?".freeze, now, id) # and the room
      end
      self.body = body
      self.updated_at = now
      @body_render = nil
      @presentation = nil
      @plain_text_body = nil
      db.execute("UPDATE message_search_index SET body = ? WHERE rowid = ?".freeze, plain_text_body, id) rescue nil
      self
    end

    # message.destroy: boosts (dependent: :destroy), rich text, attachment
    # record, search index row; touches the room.
    def destroy!(db, now: Clock.now_db)
      blob_ids = nil
      db.transaction do
        blob_ids = db.query_splat("SELECT blob_id FROM active_storage_attachments WHERE record_type = 'Message' AND record_id = ?".freeze, id)
        # Takes its boosts, rich text, attachment row and index row along (db/triggers.sql).
        db.execute("DELETE FROM messages WHERE id = ?".freeze, id)
        db.execute("UPDATE rooms SET updated_at = ? WHERE id = ?".freeze, now, room_id)
      end
      blob_ids.each { |bid| Storage.purge_later(bid) }
      Cache.invalidate(:message, id)
      self
    end
  end
end
