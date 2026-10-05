# frozen_string_literal: true

require "securerandom"

module Campfire
  # Records are Structs built straight from Extralite rows (query_splat with a
  # transform, so no intermediate row arrays). Queries are literal SQL; the
  # connection caches their prepared statements.

  class Account < Struct.new(:id, :name, :join_code, :custom_styles, :settings_json, :updated_at, :created_at)
    COLS = "id, name, join_code, custom_styles, settings, updated_at, created_at"

    def self.first(db)
      row = db.query_single_array("SELECT #{COLS} FROM accounts ORDER BY id LIMIT 1".freeze)
      row && new(*row)
    end

    def settings = (@settings ||= settings_json ? (JSON.parse(settings_json) rescue {}) : {})
    def restrict_room_creation_to_administrators? = settings["restrict_room_creation_to_administrators"] == true

    def logo_attached?(db)
      @logo_attached = Attachment.exists?(db, "Account", id, "logo") if @logo_attached.nil?
      @logo_attached
    end

    def self.generate_join_code = SecureRandom.alphanumeric(12).scan(/.{4}/).join("-")
  end

  class User < Struct.new(:id, :name, :email_address, :role, :status, :bio, :bot_token, :created_at, :updated_at)
    COLS = "id, name, email_address, role, status, bio, bot_token, created_at, updated_at"
    BY_ID = "SELECT #{COLS} FROM users WHERE id = ?".freeze
    ROLES = %w[member administrator bot].freeze
    STATUSES = %w[active deactivated banned].freeze

    def self.find(db, id)
      row = db.query_single_array(BY_ID, id)
      row && new(*row)
    end

    def self.where(db, sql, *binds)
      db.query_array("SELECT #{COLS} FROM users #{sql}", *binds).map! { |r| new(*r) }
    end

    def self.authenticate_bot(db, key)
      bot_id, token = key.split("-") # Rails: a key with more dashes still matches on the first two parts
      return nil unless bot_id && token
      row = db.query_single_array("SELECT #{COLS} FROM users WHERE id = ? AND bot_token = ? AND role = 2 AND status = 0".freeze, bot_id.to_i, token)
      row && new(*row)
    end

    def self.authenticate_by(db, email, password)
      row = db.query_single_array("SELECT #{COLS}, password_digest FROM users WHERE email_address = ?".freeze, email.to_s.strip.downcase)
      return nil unless row
      digest = row.pop
      user = new(*row)
      digest && BCrypt::Password.new(digest).is_password?(password.to_s) ? user : nil
    rescue BCrypt::Errors::InvalidHash
      nil
    end

    def member? = role == 0
    def administrator? = role == 1
    def bot? = role == 2
    def active? = status == 0
    def deactivated? = status == 1
    def banned? = status == 2

    def can_administer?(record = nil)
      administrator? || (record && record.respond_to?(:creator_id) && record.creator_id == id)
    end

    def title
      bio.nil? || bio.strip.empty? ? name : "#{name} – #{bio}"
    end

    def initials = name.scan(/\b\w/).join
    def bot_key = "#{id}-#{bot_token}"

    def avatar_token = Campfire.secrets.signed_id("User", id, purpose: "avatar")
  end

  class Session < Struct.new(:id, :user_id, :token, :last_active_at, :user_agent, :ip_address, :created_at)
    COLS = "id, user_id, token, last_active_at, user_agent, ip_address, created_at"

    def self.find_by_token(db, token)
      row = db.query_single_array("SELECT #{COLS} FROM sessions WHERE token = ?".freeze, token)
      row && new(*row)
    end

    def self.start!(db, user_id, user_agent, ip)
      now = Clock.now_db
      token = SecureRandom.base58(24)
      db.execute("INSERT INTO sessions (user_id, token, last_active_at, user_agent, ip_address, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)".freeze,
        user_id, token, now, user_agent, ip, now, now)
      new(db.last_insert_rowid, user_id, token, now, user_agent, ip, now)
    end

    def resume!(db, user_agent, ip)
      now = Clock.now_db
      db.execute("UPDATE sessions SET user_agent = ?, ip_address = ?, last_active_at = ?, updated_at = ? WHERE id = ?".freeze, user_agent, ip, now, now, id)
      self.last_active_at = now
    end

    def destroy!(db) = db.execute("DELETE FROM sessions WHERE id = ?".freeze, id)
  end

  class Room < Struct.new(:id, :name, :type, :creator_id, :created_at, :updated_at)
    COLS = "rooms.id, rooms.name, rooms.type, rooms.creator_id, rooms.created_at, rooms.updated_at"
    OPEN = "Rooms::Open"
    CLOSED = "Rooms::Closed"
    DIRECT = "Rooms::Direct"

    def self.find(db, id)
      row = db.query_single_array("SELECT #{COLS} FROM rooms WHERE id = ?".freeze, id)
      row && new(*row)
    end

    # The room, if `user_id` is a member.
    def self.find_for_user(db, user_id, id)
      row = db.query_single_array("SELECT #{COLS} FROM rooms JOIN memberships m ON m.room_id = rooms.id WHERE m.user_id = ? AND rooms.id = ?".freeze, user_id, id)
      row && new(*row)
    end

    def self.original_for_user(db, user_id)
      row = db.query_single_array("SELECT #{COLS} FROM rooms JOIN memberships m ON m.room_id = rooms.id WHERE m.user_id = ? ORDER BY rooms.created_at LIMIT 1".freeze, user_id)
      row && new(*row)
    end

    def self.last_for_user(db, user_id)
      row = db.query_single_array("SELECT #{COLS} FROM rooms JOIN memberships m ON m.room_id = rooms.id WHERE m.user_id = ? ORDER BY m.id DESC LIMIT 1".freeze, user_id)
      row && new(*row)
    end

    def open? = type == OPEN
    def closed? = type == CLOSED
    def direct? = type == DIRECT
    def default_involvement = direct? ? "everything" : "mentions"

    def user_names_except(db, user_id)
      # room.users.without(user).pluck(:name): no ORDER BY upstream, so keep
      # the exact query shape for SQLite to return rows in the same order.
      if user_id
        db.query_splat('SELECT "users"."name" FROM "users" INNER JOIN "memberships" ON "users"."id" = "memberships"."user_id" WHERE "memberships"."room_id" = ? AND "users"."id" != ?'.freeze, id, user_id)
      else
        db.query_splat('SELECT "users"."name" FROM "users" INNER JOIN "memberships" ON "users"."id" = "memberships"."user_id" WHERE "memberships"."room_id" = ?'.freeze, id)
      end
    end

    def user_ids(db) = db.query_splat("SELECT user_id FROM memberships WHERE room_id = ?".freeze, id)

    def touch!(db, now = Clock.now_db)
      db.execute("UPDATE rooms SET updated_at = ? WHERE id = ?".freeze, now, id)
      self.updated_at = now
    end
  end

  class Membership < Struct.new(:id, :room_id, :user_id, :involvement, :unread_at, :connected_at, :connections, :created_at, :updated_at)
    COLS = "memberships.id, memberships.room_id, memberships.user_id, memberships.involvement, memberships.unread_at, memberships.connected_at, memberships.connections, memberships.created_at, memberships.updated_at"
    CONNECTION_TTL = 60

    def self.find_by(db, user_id, room_id)
      row = db.query_single_array("SELECT #{COLS} FROM memberships WHERE user_id = ? AND room_id = ?".freeze, user_id, room_id)
      row && new(*row)
    end

    def unread? = !unread_at.nil?
    def visible? = involvement != "invisible"

    def connected?
      !connected_at.nil? && Clock.to_time(connected_at) >= Time.now - CONNECTION_TTL
    end
  end

  class Boost < Struct.new(:id, :message_id, :booster_id, :content, :created_at, :updated_at); end

  class Search < Struct.new(:id, :user_id, :query, :created_at, :updated_at); end

  class Attachment < Struct.new(:id, :record_type, :record_id, :name, :blob_id)
    def self.exists?(db, type, id, name)
      !db.query_single_splat("SELECT 1 FROM active_storage_attachments WHERE record_type = ? AND record_id = ? AND name = ? LIMIT 1".freeze, type, id, name).nil?
    end
  end
end
