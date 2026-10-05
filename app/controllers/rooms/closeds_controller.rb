# frozen_string_literal: true

module Campfire
  module Rooms
    class ClosedsController < BaseController
      def before_action
        case @action
        when :show, :edit, :update
          set_room
          ensure_can_administer_room if @action == :update
          remember_last_room_visited if @action == :show
          # force_room_type: a closed room's form edits an open room too.
          @room = Room.new(*@room.to_a).tap { |r| r.type = Room::CLOSED } if @action == :edit
        when :new, :create
          ensure_permission_to_create_rooms
        end
      end

      def show
        redirect_to("/rooms/#{@room.id}")
      end

      def new
        @room = Room.new(nil, DEFAULT_ROOM_NAME, Room::CLOSED, current_user.id, nil, nil)
        @users = User.active_ordered(@db)
        render_form(:new)
      end

      def create
        require_room_params!
        room = RoomOps.create!(@db, Room::CLOSED, room_name_param, current_user.id, grantee_ids)
        each_user_and_html_for(room) { |uid, html| broadcast_user_rooms(uid, turbo_stream_tag("prepend", "shared_rooms", html)) }
        redirect_to("/rooms/#{room.id}")
      end

      def edit
        selected = @room.user_ids(@db)
        @selected_users, @unselected_users = User.active_ordered(@db).partition { |u| selected.include?(u.id) }
        render_form(:edit)
      end

      def update
        require_room_params!
        @db.transaction do
          @room = RoomOps.update!(@db, @room, type: Room::CLOSED, name: room_name_param)
          granted = grantee_ids
          revoked = @room.user_ids(@db) - granted
          RoomOps.grant!(@db, @room, granted)
          RoomOps.revoke!(@db, @room, revoked)
        end
        each_user_and_html_for(@room) { |uid, html| broadcast_user_rooms(uid, turbo_stream_tag("replace", "list_#{@room.dom_key}", html)) }
        redirect_to("/rooms/#{@room.id}")
      end

      private

      # User.where(id: params.fetch(:user_ids, [])).
      def grantee_ids
        ids = params["user_ids"]
        ids = ids.is_a?(Array) ? ids : (ids.is_a?(Hash) ? ids.values : [])
        ids = ids.filter_map { |i| i.to_s.match?(/\A\s*\d+/) ? i.to_s.to_i : nil }.uniq
        return [] if ids.empty?
        @db.query_splat("SELECT id FROM users WHERE id IN (#{(["?"] * ids.size).join(",")})", *ids)
      end

      def each_user_and_html_for(room)
        html = shared_room_html(room)
        room.user_ids(@db).each { |uid| yield uid, html }
      end

      def render_form(kind)
        @page_title = kind == :new ? "New chat room" : "Edit settings for #{@room.name}"
        @nav = -> { _rooms_nav_back }
        html { frame_or_application_layout { kind == :new ? rooms_closeds_new : rooms_closeds_edit } }
      end
    end
  end
end
