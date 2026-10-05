# frozen_string_literal: true

require_relative "room_channel"

module Campfire
  # Membership::Connectable, statement for statement.
  class PresenceChannel < RoomChannel
    channel "PresenceChannel"
    actions :present, :absent, :refresh
    on_subscribe :present
    on_unsubscribe :absent

    CONNECTION_TTL = 60
    MEMBERSHIP = "SELECT id, room_id, connections, connected_at FROM memberships WHERE room_id = ? AND user_id = ? LIMIT 1"
    CONNECT = "UPDATE memberships SET connections = ?, connected_at = ?, unread_at = NULL WHERE id = ?"
    DECREMENT = "UPDATE memberships SET connections = COALESCE(connections, 0) - 1, updated_at = ? WHERE id = ?"
    INCREMENT = "UPDATE memberships SET connections = COALESCE(connections, 0) + 1, updated_at = ? WHERE id = ?"
    SET_CONNECTIONS = "UPDATE memberships SET connections = ?, updated_at = ? WHERE id = ?"
    CLEAR_CONNECTED = "UPDATE memberships SET connected_at = NULL, updated_at = ? WHERE id = ?"
    TOUCH_CONNECTED = "UPDATE memberships SET connected_at = ?, updated_at = ? WHERE id = ?"

    # Membership#present + broadcast_read_room
    def present
      m = membership or return
      connections = connected?(m) ? m[2] + 1 : 1
      db.execute(CONNECT, connections, Clock.now_db, m[0])
      Cable.broadcast(Cable.user_reads_stream(current_user.id), { room_id: m[1] })
    end

    # Membership#disconnected
    def absent
      m = membership or return
      connections = decrement_connections(m)
      db.execute(CLEAR_CONNECTED, Clock.now_db, m[0]) if connections < 1 && !m[3].nil?
    end

    # Membership#refresh_connection
    def refresh
      m = membership or return
      now = Clock.now_db
      set_connections(m, 1, now) unless connected?(m)
      db.execute(TOUCH_CONNECTED, now, now, m[0])
    end

    private

    def membership = @room && db.query_single_array(MEMBERSHIP, @room[0], current_user.id)

    def connected?(m)
      !m[3].nil? && m[3] >= Clock.from_time(Time.now - CONNECTION_TTL)
    end

    def decrement_connections(m)
      if connected?(m)
        db.execute(DECREMENT, Clock.now_db, m[0])
        m[2] - 1
      else
        set_connections(m, 0, Clock.now_db)
        0
      end
    end

    # update!(connections: n): no write when unchanged.
    def set_connections(m, n, now)
      db.execute(SET_CONNECTIONS, n, now, m[0]) unless m[2] == n
    end
  end
end
