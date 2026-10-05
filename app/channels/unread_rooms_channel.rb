# frozen_string_literal: true

require_relative "application_cable/channel"

module Campfire
  # Scoped per user, like ReadRoomsChannel.
  class UnreadRoomsChannel < ApplicationCable::Channel
    channel "UnreadRoomsChannel"

    def self.stream_name_for(user_id) = Cable.user_unreads_stream(user_id)

    def subscribed
      stream_from self.class.stream_name_for(current_user.id)
    end
  end
end
