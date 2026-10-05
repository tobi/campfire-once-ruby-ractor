# frozen_string_literal: true

module Campfire
  module Rooms
    # Rooms::InvolvementsController (RoomScoped). Frame layout for Turbo-Frame
    # requests (turbo-rails default), application layout otherwise.
    class InvolvementsController < ApplicationController
      INVOLVEMENTS = %w[invisible nothing mentions everything].freeze

      def show
        set_membership!
        html { frame_or_application_layout { rooms_involvements_show(room: @room, involvement: @membership.involvement) } }
      end

      def update
        set_membership!
        involvement = params["involvement"].to_s
        # Membership enum validation: ArgumentError -> 500 upstream; refuse instead.
        return head(422) unless INVOLVEMENTS.include?(involvement)
        was = @membership.involvement
        @db.execute("UPDATE memberships SET involvement = ?, updated_at = ? WHERE id = ?".freeze, involvement, Clock.now_db, @membership.id) if was != involvement
        broadcast_visibility_changes(was, involvement)
        redirect_to("/rooms/#{@room.id}/involvement")
      end

      private

      # RoomScoped: Current.user.memberships.find_by!(room_id:) -> 404.
      def set_membership!
        @membership = Membership.find_by(@db, current_user.id, params["room_id"].to_i) || not_found!
        @room = Room.find(@db, @membership.room_id) || not_found!
      end

      def broadcast_visibility_changes(was, now)
        return if @room.direct?
        stream = "#{RailsCompat::GID.build("User", current_user.id).to_param}:rooms"
        if now == "invisible"
          broadcast_to(stream, turbo_stream_tag("remove", "list_#{@room.dom_key}"))
        elsif was == "invisible"
          html = capture { sidebar_shared(@room.id, @room.name, @room.type, false) }
          broadcast_to(stream, turbo_stream_tag("prepend", "shared_rooms", html))
        end
      end
    end
  end
end
