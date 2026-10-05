# frozen_string_literal: true

require_relative "application_cable/channel"

module Campfire
  class HeartbeatChannel < ApplicationCable::Channel
    channel "HeartbeatChannel"
  end
end
