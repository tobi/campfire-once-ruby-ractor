# frozen_string_literal: true

module Campfire
  module Messages
    # Messages::BoostsController. No explicit layout upstream, so turbo-rails'
    # frame layout applies to Turbo-Frame requests.
    class BoostsController < ApplicationController
      def index
        message = set_message!
        full = Message.load_one(@db, message.id)
        html { frame_or_application_layout { messages_boosts_index(message: full) } }
      end

      def new
        message = set_message!
        html { frame_or_application_layout { messages_boosts_new(message: message, bpath: boosts_path(message)) } }
      end

      def create
        message = set_message!
        attrs = params["boost"]
        return head(400) unless attrs.is_a?(Hash) && attrs["content"].is_a?(String)
        boost = message.create_boost!(@db, current_user, attrs["content"])
        broadcast_boost_append(message, boost)
        redirect_to(boosts_path(message))
      end

      # Upstream renders no template: 204 for the turbo request.
      def destroy
        message = set_message!
        boost_id = message.destroy_boost!(@db, params["id"], current_user.id) || not_found!
        broadcast_boost_remove(message, boost_id)
        head(204)
      end

      private

      # broadcast_create: the boost partial appended to the message's boosts.
      def broadcast_boost_append(message, boost)
        fragment = MessageBroadcasts.boost_fragment(@db, boost, host_without_port, renderer_base_url)
        broadcast_to(Cable.room_messages_stream(*room_of(message)),
          turbo_stream_tag("append", "boosts_message_#{message.client_message_id}", fragment, maintain_scroll: true))
      end

      # broadcast_remove
      def broadcast_boost_remove(message, boost_id)
        broadcast_to(Cable.room_messages_stream(*room_of(message)), turbo_stream_tag("remove", "boost_#{boost_id}"))
      end

      # Current.user.reachable_messages.find(params[:message_id])
      def set_message!
        Message.find_reachable(@db, current_user.id, params["message_id"]) || not_found!
      end

      def boosts_path(message) = "/messages/#{message.id}/boosts"

      def room_of(message)
        type = @db.query_single_splat("SELECT type FROM rooms WHERE id = ?".freeze, message.room_id)
        [type, message.room_id]
      end
    end
  end
end
