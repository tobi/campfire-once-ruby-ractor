# frozen_string_literal: true

require_relative "room_channel"

module Campfire
  class TypingNotificationsChannel < RoomChannel
    channel "TypingNotificationsChannel"
    actions :start, :stop

    def start(_data)
      broadcast_to @room, { action: "start", user: current_user_attributes }
    end

    def stop(_data)
      broadcast_to @room, { action: "stop", user: current_user_attributes }
    end

    private

    def current_user_attributes = { id: current_user.id, name: current_user.name }
  end
end
