# frozen_string_literal: true

module Campfire
  module Rooms
    class DirectsController < BaseController
      # room.users.without(Current.user) / room.users (no ORDER BY upstream).
      USERS_WITHOUT = %(SELECT #{User::COLS.gsub(/(\w+)/, '"users"."\1"')} FROM "users" INNER JOIN "memberships" ON "users"."id" = "memberships"."user_id" WHERE "memberships"."room_id" = ? AND "users"."id" != ?).freeze
      USERS = %(SELECT #{User::COLS.gsub(/(\w+)/, '"users"."\1"')} FROM "users" INNER JOIN "memberships" ON "users"."id" = "memberships"."user_id" WHERE "memberships"."room_id" = ?).freeze

      def before_action
        set_room if @action == :edit || @action == :destroy
      end

      # Routed (resources :directs) but upstream has no rooms/directs/show template, so Rails
      # answers 500. Deliberate divergence (as once-campfire-rust): redirect to the room page,
      # which checks membership.
      def show
        id = params["id"].to_s
        not_found! unless id.match?(/\A\s*[+-]?\d/)
        redirect_to("/rooms/#{id.to_i}")
      end

      def new
        html { frame_or_application_layout { rooms_directs_new } }
      end

      def create
        ids = params["user_ids"]
        ids = ids.is_a?(Array) ? ids : (ids.is_a?(Hash) ? ids.values : [])
        ids = (ids.filter_map { |i| i.to_s.match?(/\A\s*\d+/) ? i.to_s.to_i : nil } << current_user.id).uniq
        ids = @db.query_splat("SELECT id FROM users WHERE id IN (#{(["?"] * ids.size).join(",")})", *ids)
        room, _created = RoomOps.find_or_create_direct!(@db, ids, current_user.id)
        broadcast_create_room(room)
        redirect_to("/rooms/#{room.id}")
      end

      def edit
        users = @db.query_array(USERS, @room.id).map! { |r| User.new(*r) }
        @users = users.size > 1 ? @db.query_array(USERS_WITHOUT, @room.id, current_user.id).map! { |r| User.new(*r) } : users
        @page_title = "Edit settings for #{room_display_name(@room)}"
        @nav = -> { _rooms_nav_back }
        html { frame_or_application_layout { rooms_directs_edit } }
      end

      # RoomsController#destroy (all members of a direct room may administer it).
      def destroy
        RoomOps.destroy!(@db, @room)
        broadcast_rooms(turbo_stream_tag("remove", "list_#{@room.dom_key}"))
        redirect_to("/")
      end

      private

      def room_scope_sql = SCOPE_DIRECTS

      MEMBERSHIPS = "SELECT m.id, m.updated_at, m.unread_at, m.user_id FROM memberships m WHERE m.room_id = ? ORDER BY m.id".freeze

      def broadcast_create_room(room)
        @db.query_array(MEMBERSHIPS, room.id).each do |mid, mupdated, unread, uid|
          user = User.find(@db, uid) or next
          item = Sidebar::Item.new(mid, mupdated, !unread.nil?, room.id, room.name, room.type, room.updated_at)
          html = capture { sidebar_direct(item, user) }
          broadcast_user_rooms(uid, turbo_stream_tag("prepend", "direct_rooms", html))
        end
      end
    end
  end
end
