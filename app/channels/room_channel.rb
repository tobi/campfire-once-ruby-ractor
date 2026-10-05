# frozen_string_literal: true

require_relative "application_cable/channel"

module Campfire
  class RoomChannel < ApplicationCable::Channel
    channel "RoomChannel"

    def subscribed
      if (@room = find_user_room(params["room_id"]))
        stream_for @room
      else
        reject
      end
    end
  end
end
