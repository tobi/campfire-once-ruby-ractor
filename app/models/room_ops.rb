# frozen_string_literal: true

require "set"
require_relative "models"

module Campfire
  # Room creation, membership granting/revoking, type changes and deletion
  # (upstream Room.create_for, Room#memberships.grant_to/revoke_from/revise,
  # Rooms::Open#grant_access_to_all_users, Rooms::Direct.find_or_create_for,
  # Room#destroy).
  module RoomOps
    INSERT_MEMBERSHIP = "INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT (room_id, user_id) DO NOTHING"
    DOM_PREFIX = { Room::OPEN => "rooms_open", Room::CLOSED => "rooms_closed", Room::DIRECT => "rooms_direct" }.freeze

    ROOM_USERS = "SELECT #{User::COLS.gsub(/(\w+)/, 'users.\1')} FROM users INNER JOIN memberships ON users.id = memberships.user_id WHERE memberships.room_id = ?".freeze

    module_function

    def dom_key(room) = "#{DOM_PREFIX.fetch(room.type)}_#{room.id}"

    def default_involvement(type) = type == Room::DIRECT ? "everything" : "mentions"

    # Room.create_for(attributes, users:). Returns the Room.
    def create!(db, type, name, creator_id, user_ids, now: Clock.now_db)
      db.transaction do
        db.execute("INSERT INTO rooms (name, type, creator_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)".freeze, name, type, creator_id, now, now)
        room = Room.new(db.last_insert_rowid, name, type, creator_id, now, now)
        grant!(db, room, user_ids, now: now)
        # Rooms::Open after_save_commit: type_previously_changed?(to: Open) is true on create.
        grant!(db, room, active_user_ids(db), now: now) if type == Room::OPEN
        room
      end
    end

    # memberships.grant_to(users): insert_all, skipping existing memberships.
    def grant!(db, room, user_ids, now: Clock.now_db)
      involvement = default_involvement(room.type)
      user_ids.each { |uid| db.execute(INSERT_MEMBERSHIP, room.id, uid, involvement, now, now) }
    end

    # memberships.revoke_from(users): destroy_by, so each revoked user's cable
    # connections are reset (Membership after_destroy_commit).
    def revoke!(db, room, user_ids)
      user_ids.each do |uid|
        db.execute("DELETE FROM memberships WHERE room_id = ? AND user_id = ?".freeze, room.id, uid)
      end
      user_ids.each { |uid| Cable.disconnect_user(uid, reconnect: true) } if defined?(Cable) && Cable.respond_to?(:disconnect_user)
    end

    # New users join every open room (User after_create_commit).
    def grant_open_rooms_to(db, user_id, now = Clock.now_db)
      db.query_splat("SELECT id FROM rooms WHERE type = 'Rooms::Open'".freeze).each do |rid|
        db.execute(INSERT_MEMBERSHIP, rid, user_id, "mentions", now, now)
      end
    end

    def active_user_ids(db) = db.query_splat("SELECT id FROM users WHERE status = 0".freeze)

    # @room.becomes!(klass).update!(name:): writes the new type and name,
    # bumping updated_at only when something changed. An open room created by
    # conversion grants everyone access. Returns the updated Room.
    def update!(db, room, type:, name:, now: Clock.now_db)
      raise ArgumentError, "Type can't be changed for a direct room" if room.direct? && type != Room::DIRECT
      changed_type = room.type != type
      new_name = name.nil? ? room.name : name
      if changed_type || new_name != room.name
        db.execute("UPDATE rooms SET type = ?, name = ?, updated_at = ? WHERE id = ?".freeze, type, new_name, now, room.id)
        room = Room.new(room.id, new_name, type, room.creator_id, room.created_at, now)
      else
        room = Room.new(room.id, room.name, type, room.creator_id, room.created_at, room.updated_at)
      end
      grant!(db, room, active_user_ids(db), now: now) if changed_type && type == Room::OPEN
      room
    end

    # Rooms::Direct.find_or_create_for(users): the direct room whose member
    # set equals `user_ids`, else a new one.
    def find_or_create_direct!(db, user_ids, creator_id, now: Clock.now_db)
      want = user_ids.to_set
      rows = db.query_array("SELECT r.id, m.user_id FROM rooms r JOIN memberships m ON m.room_id = r.id WHERE r.type = 'Rooms::Direct' ORDER BY r.id".freeze)
      members = {}
      rows.each { |rid, uid| (members[rid] ||= Set.new) << uid }
      if (rid = members.find { |_, set| set == want }&.first)
        return [Room.find(db, rid), false]
      end
      [create!(db, Room::DIRECT, nil, creator_id, user_ids, now: now), true]
    end

    # Room#destroy: memberships delete_all, messages destroy (boosts, rich
    # text, attachments, search index rows). Blobs are purged later.
    def destroy!(db, room)
      blob_ids = nil
      db.transaction do
        blob_ids = db.query_splat("SELECT a.blob_id FROM active_storage_attachments a JOIN messages m ON a.record_type = 'Message' AND a.record_id = m.id WHERE m.room_id = ?".freeze, room.id)
        # Memberships and messages (with everything hanging off them) go too (db/triggers.sql).
        db.execute("DELETE FROM rooms WHERE id = ?".freeze, room.id)
      end
      blob_ids.each { |bid| Jobs.later(:purge, bid) } if Jobs::HANDLERS.key?(:purge)
      room
    end

    # room.users.without(user) names, membership order (to_sentence input).
    def member_names_except(db, room_id, user_id)
      db.query_splat("SELECT u.name FROM users u JOIN memberships m ON m.user_id = u.id WHERE m.room_id = ? AND u.id != ? ORDER BY m.id".freeze, room_id, user_id)
    end

    # room.users (membership order).
    def users(db, room_id)
      db.query_array(ROOM_USERS, room_id).map! { |r| User.new(*r) }
    end
  end
end

module Campfire
  class Room
    # user.rooms.without_directs.ordered
    def self.for_bot_listing(db, user_id)
      db.query_array("SELECT #{COLS} FROM rooms JOIN memberships m ON m.room_id = rooms.id WHERE m.user_id = ? AND rooms.type != 'Rooms::Direct' ORDER BY LOWER(rooms.name)".freeze, user_id).map! { |r| new(*r) }
    end
  end
end
