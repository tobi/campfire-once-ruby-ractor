# frozen_string_literal: true

module Campfire
  module Rooms
    # Rooms::RefreshesController (RoomScoped): messages created / updated
    # since `since` (epoch ms), as the turbo streams rooms/refreshes/show
    # produces (an append of the new ones, then one replace per updated one).
    class RefreshesController < ApplicationController
      def show
        room = Room.find_for_user(@db, current_user.id, params["room_id"].to_i) || not_found!
        since = Message.time_bind_from_ms(params["since"].to_i)
        created = Message.page_created_since(@db, room.id, since)
        updated = Message.page_updated_since(@db, room.id, since, created.ids)
        turbo_stream do
          @b << turbo_stream_tag("append", "messages_#{room.dom_key}", "\n  #{capture { render_messages(created, room) }}\n") if created.any?
          @b << "\n"
          if updated.any?
            room_name = room_display_name(room, nil)
            loaded = Message.load_presentation(@db, updated.ids)
            updated.ids.each do |id|
              next unless (m = loaded[id])
              @b << "  " << turbo_stream_tag("replace", "message_#{m.client_message_id}", cached_message(m.context!(host_without_port, user_resolver), room_name)) << "\n"
            end
          end
        end
      end
    end
  end
end
