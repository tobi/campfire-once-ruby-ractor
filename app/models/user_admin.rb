# frozen_string_literal: true

require "ipaddr"
require_relative "models"

module Campfire
  # Administrative user writes (upstream User#deactivate, User::Role,
  # User::Bannable, User::Bot) and the user lists the admin pages show.
  class User
    ORDERED = "ORDER BY LOWER(name)"

    class << self
      # User.active.ordered(.without_bots)
      def active_ordered(db, without_bots: false)
        sql = without_bots ?
          "SELECT #{COLS} FROM users WHERE status = 0 AND role != 2 ORDER BY LOWER(name)".freeze :
          "SELECT #{COLS} FROM users WHERE status = 0 ORDER BY LOWER(name)".freeze
        db.query_array(sql).map! { |r| new(*r) }
      end

      # AccountsController#account_users.ordered.without_bots
      def account_users(db, include_banned:)
        sql = include_banned ?
          "SELECT #{COLS} FROM users WHERE status IN (0, 2) AND role != 2 ORDER BY LOWER(name)".freeze :
          "SELECT #{COLS} FROM users WHERE status = 0 AND role != 2 ORDER BY LOWER(name)".freeze
        db.query_array(sql).map! { |r| new(*r) }
      end

      def active_bots(db)
        db.query_array("SELECT #{COLS} FROM users WHERE status = 0 AND role = 2 ORDER BY LOWER(name)".freeze).map! { |r| new(*r) }
      end

      def find_active(db, id)
        row = db.query_single_array("SELECT #{COLS} FROM users WHERE id = ? AND status = 0".freeze, id.to_i)
        row && new(*row)
      end

      def find_active_bot(db, id)
        row = db.query_single_array("SELECT #{COLS} FROM users WHERE id = ? AND status = 0 AND role = 2".freeze, id.to_i)
        row && new(*row)
      end

      def generate_bot_token = SecureRandom.alphanumeric(12)

      # User.create_bot!: the bot joins every open room (after_create_commit).
      def create_bot!(db, name:, webhook_url: nil, now: Clock.now_db)
        db.transaction do
          db.execute("INSERT INTO users (name, role, status, bot_token, created_at, updated_at) VALUES (?, 2, 0, ?, ?, ?)".freeze,
            name.to_s, generate_bot_token, now, now)
          id = db.last_insert_rowid
          if webhook_url
            db.execute("INSERT INTO webhooks (user_id, url, created_at, updated_at) VALUES (?, ?, ?, ?)".freeze, id, webhook_url, now, now)
          end
          RoomOps.grant_open_rooms_to(db, id, now)
          find(db, id)
        end
      end
    end

    def ==(other) = other.is_a?(User) && other.id == id
    alias_method :eql?, :==
    def hash = id.hash

    def webhook_url(db)
      db.query_single_splat("SELECT url FROM webhooks WHERE user_id = ? ORDER BY id LIMIT 1".freeze, id)
    end

    def avatar_attached?(db) = Attachment.exists?(db, "User", id, "avatar")

    # User::Role via Accounts::UsersController#role_params.
    def update_role!(db, role_name, now: Clock.now_db)
      role_value = role_name == "administrator" ? 1 : 0
      return false if role == role_value
      db.execute("UPDATE users SET role = ?, updated_at = ? WHERE id = ?".freeze, role_value, now, id)
      self.role = role_value
      self.updated_at = now
      true
    end

    # Users::ProfilesController#update (name, email_address, password, bio).
    def update_profile!(db, attrs, now: Clock.now_db)
      sets = nil
      binds = nil
      if attrs.key?("name") && attrs["name"] != name
        (sets ||= []) << "name = ?"
        (binds ||= []) << (self.name = attrs["name"])
      end
      if attrs.key?("email_address") && attrs["email_address"] != email_address
        (sets ||= []) << "email_address = ?"
        (binds ||= []) << (self.email_address = attrs["email_address"].to_s.strip.downcase)
      end
      if attrs.key?("bio") && attrs["bio"] != bio
        (sets ||= []) << "bio = ?"
        (binds ||= []) << (self.bio = attrs["bio"])
      end
      if (pw = attrs["password"]) && !pw.empty?
        (sets ||= []) << "password_digest = ?"
        (binds ||= []) << BCrypt::Password.create(pw).to_s
      end
      return false unless sets
      sets << "updated_at = ?"
      binds << now
      db.execute("UPDATE users SET #{sets.join(", ")} WHERE id = ?", *binds, id)
      self.updated_at = now
      true
    end

    # Touch after an avatar change (the avatar ETag and ?v= depend on it).
    def touch!(db, now: Clock.now_db)
      db.execute("UPDATE users SET updated_at = ? WHERE id = ?".freeze, now, id)
      self.updated_at = now
    end

    # User#deactivate
    def deactivate!(db, now: Clock.now_db)
      db.transaction do
        db.execute("DELETE FROM memberships WHERE user_id = ? AND room_id IN (SELECT id FROM rooms WHERE type != 'Rooms::Direct')".freeze, id)
        db.execute("DELETE FROM push_subscriptions WHERE user_id = ?".freeze, id)
        db.execute("DELETE FROM searches WHERE user_id = ?".freeze, id)
        db.execute("DELETE FROM sessions WHERE user_id = ?".freeze, id)
        email = email_address&.gsub("@", "-deactivated-#{SecureRandom.uuid}@")
        db.execute("UPDATE users SET status = 1, email_address = ?, updated_at = ? WHERE id = ?".freeze, email, now, id)
        self.status = 1
        self.email_address = email
        self.updated_at = now
      end
      close_remote_connections
    end

    # User::Bannable#ban
    def ban!(db, now: Clock.now_db)
      db.transaction do
        ips = db.query_splat("SELECT DISTINCT ip_address FROM sessions WHERE user_id = ? ORDER BY id".freeze, id)
        seen = {}
        ips.each do |ip|
          next if ip.nil? || ip.strip.empty? || seen[ip]
          seen[ip] = true
          Ban.create!(db, id, ip, now)
        end
        db.execute("DELETE FROM sessions WHERE user_id = ?".freeze, id)
        db.execute("UPDATE users SET status = 2, updated_at = ? WHERE id = ?".freeze, now, id)
        self.status = 2
        self.updated_at = now
      end
      close_remote_connections
      Jobs.later(:remove_banned_content, id) if Jobs::HANDLERS.key?(:remove_banned_content)
    end

    # User::Bannable#unban
    def unban!(db, now: Clock.now_db)
      db.transaction do
        db.execute("DELETE FROM bans WHERE user_id = ?".freeze, id)
        db.execute("UPDATE users SET status = 0, updated_at = ? WHERE id = ?".freeze, now, id)
      end
      self.status = 0
      self.updated_at = now
    end

    # User::Bot#update_bot!
    def update_bot!(db, name:, webhook_url:, now: Clock.now_db)
      db.transaction do
        if webhook_url && !webhook_url.strip.empty?
          wid = db.query_single_splat("SELECT id FROM webhooks WHERE user_id = ? ORDER BY id LIMIT 1".freeze, id)
          if wid
            current = db.query_single_splat("SELECT url FROM webhooks WHERE id = ?".freeze, wid)
            if current != webhook_url
              db.execute("UPDATE webhooks SET url = ?, updated_at = ? WHERE id = ?".freeze, webhook_url, now, wid)
            end
          else
            db.execute("INSERT INTO webhooks (user_id, url, created_at, updated_at) VALUES (?, ?, ?, ?)".freeze, id, webhook_url, now, now)
          end
        else
          db.execute("DELETE FROM webhooks WHERE user_id = ?".freeze, id)
        end
        if !name.nil? && name != self.name
          db.execute("UPDATE users SET name = ?, updated_at = ? WHERE id = ?".freeze, name, now, id)
          self.name = name
          self.updated_at = now
        end
      end
    end

    def reset_bot_key!(db, now: Clock.now_db)
      self.bot_token = User.generate_bot_token
      db.execute("UPDATE users SET bot_token = ?, updated_at = ? WHERE id = ?".freeze, bot_token, now, id)
      self.updated_at = now
    end

    private

    def close_remote_connections(reconnect: false)
      Cable.disconnect_user(id, reconnect: reconnect) if defined?(Cable) && Cable.respond_to?(:disconnect_user)
    end
  end
end
