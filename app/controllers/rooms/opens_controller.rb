# frozen_string_literal: true

module Campfire
  module Rooms
    class OpensController < BaseController
      def before_action
        case @action
        when :show, :edit, :update
          set_room
          ensure_can_administer_room if @action == :update
          remember_last_room_visited if @action == :show
          # force_room_type: an open room's form edits a closed room too.
          # (update passes the original type to RoomOps.update!, which grants
          # everyone access when an open room is created by conversion.)
          @room = Room.new(*@room.to_a).tap { |r| r.type = Room::OPEN } if @action == :edit
        when :new, :create
          ensure_permission_to_create_rooms
        end
      end

      def show
        redirect_to("/rooms/#{@room.id}")
      end

      def new
        @room = Room.new(nil, DEFAULT_ROOM_NAME, Room::OPEN, current_user.id, nil, nil)
        @users = User.active_ordered(@db)
        render_form(:new)
      end

      def create
        require_room_params!
        room = RoomOps.create!(@db, Room::OPEN, room_name_param, current_user.id, [current_user.id])
        broadcast_rooms(turbo_stream_tag("prepend", "shared_rooms", shared_room_html(room)))
        redirect_to("/rooms/#{room.id}")
      end

      def edit
        @users = User.active_ordered(@db)
        render_form(:edit)
      end

      def update
        require_room_params!
        @room = RoomOps.update!(@db, @room, type: Room::OPEN, name: room_name_param)
        broadcast_rooms(turbo_stream_tag("replace", "list_#{@room.dom_key}", shared_room_html(@room)))
        redirect_to("/rooms/#{@room.id}")
      end

      private

      def render_form(kind)
        @page_title = kind == :new ? "New chat room" : "Edit settings for #{@room.name}"
        @nav = -> { _rooms_nav_back }
        html { frame_or_application_layout { kind == :new ? rooms_opens_new : rooms_opens_edit } }
      end
    end
  end
end
