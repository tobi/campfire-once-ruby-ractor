# frozen_string_literal: true

module Campfire
  module Rooms
    # The RoomsController parts Rooms::{Opens,Closeds,Directs}Controller
    # inherit upstream (set_room / room_scope / ensure_permission_to_create_rooms
    # / broadcasts). RoomsController itself loads after app/controllers/rooms/,
    # so the subclasses share this base instead.
    class BaseController < ApplicationController
      SCOPE_WITHOUT_DIRECTS = "SELECT #{Room::COLS} FROM rooms JOIN memberships m ON m.room_id = rooms.id WHERE m.user_id = ? AND rooms.id = ? AND rooms.type != 'Rooms::Direct'".freeze
      SCOPE_DIRECTS = "SELECT #{Room::COLS} FROM rooms JOIN memberships m ON m.room_id = rooms.id WHERE m.user_id = ? AND rooms.id = ? AND rooms.type = 'Rooms::Direct'".freeze
      ROOM_NOT_FOUND = "Room not found or inaccessible"
      DEFAULT_ROOM_NAME = "New room"
      # ActionDispatch::PublicExceptions serves public/*.html with this type.
      PUBLIC_HTML = "text/html; charset=UTF-8"

      private

      # Subclasses narrow the scope to the room types they may act on.
      def room_scope_sql = SCOPE_WITHOUT_DIRECTS

      def set_room
        id = params["room_id"] || params["id"]
        row = id && @db.query_single_array(room_scope_sql, current_user.id, id.to_s.to_i)
        if row
          @room = Room.new(*row)
        else
          redirect_to("/", alert: ROOM_NOT_FOUND)
          throw :halt
        end
      end

      def ensure_can_administer_room
        ensure_can_administer(@room)
      end

      def ensure_permission_to_create_rooms
        if account.restrict_room_creation_to_administrators? && !current_user.administrator?
          filter_head(403)
        end
      end

      def room_name_param
        r = params["room"]
        r.is_a?(Hash) ? r["name"] : nil
      end

      def require_room_params!
        unless params["room"].is_a?(Hash)
          head(400)
          throw :halt
        end
      end

      # A shared room's sidebar entry (users/sidebars/rooms/_shared).
      def shared_room_html(room)
        capture { sidebar_shared(room.id, room.name, room.type, false) }
      end

      def broadcast_rooms(html) = Cable.broadcast("rooms", html)

      def broadcast_user_rooms(user_id, html)
        Cable.broadcast("#{RailsCompat::GID.build("User", user_id).to_param}:rooms", html)
      end
    end
  end
end
