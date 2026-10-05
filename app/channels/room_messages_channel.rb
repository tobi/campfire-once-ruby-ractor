# frozen_string_literal: true

require_relative "application_cable/channel"

module Campfire
  # Authorizes the room message stream when the subscription is made, so that
  # revoking a membership stops delivery (Turbo::StreamsChannel refuses these
  # names, so this is the only way onto them).
  class RoomMessagesChannel < ApplicationCable::Channel
    channel "RoomMessagesChannel"
    STREAM_SUFFIX = "messages"
    ROOM_CLASSES = ["Room", "Rooms::Open", "Rooms::Closed", "Rooms::Direct"].freeze
    ROOM_BY_ID = "SELECT id, type FROM rooms WHERE id = ? LIMIT 1"

    def self.guarded_stream?(stream_name)
      stream_name.to_s.split(":", 2)[1] == STREAM_SUFFIX
    end

    # GlobalID::Locator.locate(gid_param, only: Room), then user.rooms.find_by(id:).
    def self.subscribable_room(db, user_id, stream_name)
      gid_param, suffix = stream_name.to_s.split(":", 2)
      return nil unless suffix == STREAM_SUFFIX
      gid = RailsCompat::GlobalID.parse(gid_param) or return nil
      return nil unless ROOM_CLASSES.include?(gid.model_name)
      id = Cable::Channel.cast_id(gid.id) or return nil
      room = db.query_single_array(ROOM_BY_ID, id) or return nil
      return nil unless gid.model_name == "Room" || gid.model_name == room[1]
      db.query_single_array(Cable::Channel::ROOM_FOR_USER, user_id, room[0])
    end

    def subscribed
      if (stream_name = authorized_stream_name)
        stream_from stream_name
      else
        reject
      end
    end

    private

    def authorized_stream_name
      stream_name = Turbo::StreamsChannel.verified_stream_name(params["signed_stream_name"])
      stream_name if stream_name && !stream_name.to_s.empty? && self.class.subscribable_room(db, current_user.id, stream_name)
    end
  end
end
