# frozen_string_literal: true

require_relative "application_cable/channel"

module Campfire
  class ReadRoomsChannel < ApplicationCable::Channel
    channel "ReadRoomsChannel"

    def subscribed
      stream_from Cable.user_reads_stream(current_user.id)
    end
  end
end
