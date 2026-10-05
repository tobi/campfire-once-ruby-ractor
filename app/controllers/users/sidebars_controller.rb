# frozen_string_literal: true

module Campfire
  module Users
    class SidebarsController < ApplicationController
      def show
        directs, others = Sidebar.memberships(@db, current_user.id)
        html do
          frame_or_application_layout { _users_sidebars_frame(directs: directs, others: others, user: current_user) }
        end
      end
    end
  end
end
