# frozen_string_literal: true

require_relative "../boosts_controller"
require_relative "../by_bots_controller"

module Campfire
  module Messages
    module Boosts
      # Messages::Boosts::ByBotsController: bots boost with the raw request body
      # as the content.
      class ByBotsController < Messages::BoostsController
        include BotApi

        allow_bot_access only: %i[create destroy]

        # POST /rooms/:room_id/:bot_key/messages/:message_id/boosts
        def create
          message = set_message!
          content = raw_request_body
          filter_head(422) if blank?(content) # ensure_content_present
          boost = message.create_boost!(@db, current_user, content)
          broadcast_boost_append(message, boost)
          json(boost_json(boost, message, boost.updated_at), 201) # created_at == updated_at
        end

        # DELETE /rooms/:room_id/:bot_key/messages/:message_id/boosts/:id
        def destroy
          message = set_message!
          # set_boost: find_by!(id:, booster: Current.user), RecordNotFound -> head :not_found
          boost_id = message.destroy_boost!(@db, params["id"], current_user.id) or filter_head(404)
          broadcast_boost_remove(message, boost_id)
          head(204)
        end

        private

        # The room among Current.user.rooms, then its message; head :not_found without one.
        def set_message!
          room = Room.find_for_user(@db, current_user.id, params["room_id"].to_i)
          message = room && Message.find_in_room(@db, room.id, params["message_id"])
          message || filter_head(404)
        end
      end
    end
  end
end
