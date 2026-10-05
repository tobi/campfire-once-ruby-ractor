# frozen_string_literal: true

module Campfire
  module Turbo
    # Turbo::StreamsChannel with RoomStreamsAreAuthorized prepended.
    class StreamsChannel < Cable::Channel
      channel "Turbo::StreamsChannel"

      def self.verified_stream_name(signed)
        return nil unless signed.is_a?(String)
        name = Campfire.secrets.verified_stream_name(signed)
        name.nil? ? nil : name.to_s
      end

      def subscribed
        stream_name = self.class.verified_stream_name(params["signed_stream_name"])
        if stream_name.nil? || RoomMessagesChannel.guarded_stream?(stream_name)
          reject
        else
          stream_from stream_name
        end
      end
    end
  end
end
