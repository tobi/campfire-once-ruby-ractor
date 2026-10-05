# frozen_string_literal: true

module Campfire
  module Users
    class ProfilesController < ApplicationController
      # Current.user.memberships.with_ordered_room
      MEMBERSHIPS = "SELECT #{Room::COLS}, memberships.involvement FROM memberships INNER JOIN rooms ON rooms.id = memberships.room_id WHERE memberships.user_id = ? ORDER BY LOWER(rooms.name)".freeze

      def before_action
        @user = current_user
      end

      def show
        rows = @db.query_array(MEMBERSHIPS, @user.id).map { |r| [Room.new(*r[0, 6]), r[6]] }
        @direct_memberships, @shared_memberships = rows.partition { |room, _| room.direct? }
        @avatar_attached = @user.avatar_attached?(@db)
        @page_title = @user.name
        @nav = -> { _users_profiles_nav }
        html { frame_or_application_layout { users_profiles_show } }
      end

      def update
        attrs = params["user"]
        unless attrs.is_a?(Hash)
          head(400)
          throw :halt
        end
        avatar = attrs["avatar"]
        @user.update_profile!(@db, attrs.slice("name", "email_address", "password", "bio").compact)
        Accounts::BotsController.attach_avatar(@db, @user, avatar)
        redirect_to("/users/me/profile", notice: avatar ? "It may take up to 30 minutes to change everywhere." : "✓")
      end
    end
  end
end
