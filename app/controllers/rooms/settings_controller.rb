# frozen_string_literal: true

module Campfire
  module Rooms
    # Routed upstream but the controller doesn't exist: Rails answers 500.
    class SettingsController < ApplicationController
      def show
        text(Assets.file("/500.html")&.body || "", 500, Rooms::BaseController::PUBLIC_HTML)
      end
    end
  end
end
