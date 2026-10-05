# frozen_string_literal: true

module Campfire
  class WelcomeController < ApplicationController
    HAS_ROOMS_SQL = "SELECT 1 FROM rooms INNER JOIN memberships ON rooms.id = memberships.room_id WHERE memberships.user_id = ? LIMIT 1".freeze

    def show
      if @db.query_single_splat(HAS_ROOMS_SQL, current_user.id) && (room = last_room_visited)
        redirect_to("/rooms/#{room.id}")
      else
        @page_title = "No rooms yet"
        @body_class = "sidebar"
        @sidebar = -> { sidebar_turbo_frame_open("/users/me/sidebar"); @b << "</turbo-frame>"; nil }
        html { layout { welcome_show } }
      end
    end
  end
end
