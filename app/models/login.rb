# frozen_string_literal: true

require "securerandom"

# ActiveSupport's SecureRandom.base58 (has_secure_token; Session.start!).
unless SecureRandom.respond_to?(:base58)
  module SecureRandom
    BASE58_ALPHABET = (("0".."9").to_a + ("A".."Z").to_a + ("a".."z").to_a - ["0", "O", "I", "l"]).join.freeze

    def self.base58(n = 16)
      s = String.new(capacity: n, encoding: Encoding::UTF_8)
      SecureRandom.random_bytes(n).each_byte do |byte|
        idx = byte % 64
        idx = SecureRandom.random_number(58) if idx >= 58
        s << BASE58_ALPHABET[idx]
      end
      s
    end
  end
end

module Campfire
  # SessionsController#create: User.active.authenticate_by(email_address:,
  # password:) and its `rate_limit to: 10, within: 3.minutes`.
  module Login
    ACTIVE_USER_SQL = "SELECT id, password_digest FROM users WHERE status = 0 AND email_address = ? LIMIT 1".freeze

    # has_secure_password hashes a throwaway password when no record matches
    # so a miss costs the same as a wrong password. Same cost as the seeded
    # digests (BCrypt::Engine::DEFAULT_COST).
    DUMMY_DIGEST = BCrypt::Password.create("campfire-dummy-password", cost: BCrypt::Engine::DEFAULT_COST).to_s.freeze

    RATE_LIMIT = 10
    RATE_WINDOW = 180

    INSERT_USER_SQL = "INSERT INTO users (name, email_address, password_digest, role, status, created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?)".freeze

    module_function

    # User.create!(name:, email_address:, password:) plus
    # grant_membership_to_open_rooms. => new user id, or nil when the email
    # is taken (ActiveRecord::RecordNotUnique). role: 0 member, 1 administrator.
    def create_user!(db, name, email, password, role: 0, now: Clock.now_db)
      digest = password.is_a?(String) && !password.empty? ? BCrypt::Password.create(password, cost: BCrypt::Engine.cost).to_s : nil
      db.transaction do
        db.execute(INSERT_USER_SQL, name, email, digest, role, now, now)
        id = db.last_insert_rowid
        RoomOps.grant_open_rooms_to(db, id, now)
        id
      end
    rescue Extralite::Error => e
      raise unless e.message.include?("UNIQUE constraint failed: users.email_address")
      nil
    end

    # => user id or nil. The email is matched exactly (upstream has no
    # `normalizes`); a blank password short-circuits like authenticate_by.
    def authenticate(db, email, password)
      return nil unless email.is_a?(String) && password.is_a?(String)
      return nil if password.empty?
      id, digest = db.query_single_splat(ACTIVE_USER_SQL, email)
      if id
        id if digest && valid_password?(digest, password)
      else
        valid_password?(DUMMY_DIGEST, password)
        nil
      end
    end

    def valid_password?(digest, password)
      BCrypt::Password.new(digest).is_password?(password)
    rescue BCrypt::Errors::InvalidHash
      false
    end

    # Fixed-window counter like Rails' cache.increment(key, 1, expires_in:):
    # the window starts at the first hit. Counts are per worker Ractor (Rails
    # keeps them in its cache store), so the effective limit scales with
    # WEB_CONCURRENCY. Returns true when the request is over the limit.
    def rate_limited?(key, now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second))
      t = Cache.table(:rate_limit)
      entry = t[key]
      if entry.nil? || now - entry[0] >= RATE_WINDOW
        t.clear if t.size >= Cache::LIMIT
        t[key] = entry = [now, 0]
      end
      entry[1] += 1
      entry[1] > RATE_LIMIT
    end
  end
end
