# frozen_string_literal: true

module Campfire
  module ApplicationCable
    # Subscribable by name like any other ActionCable::Channel::Base descendant.
    class Channel < Cable::Channel
      channel "ApplicationCable::Channel"
    end
  end
end
