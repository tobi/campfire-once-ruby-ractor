# frozen_string_literal: true

module Campfire
  # What happens around a new message besides rendering it: Room#receive
  # (after_create_commit), Message::Broadcasts#broadcast_unread_room and
  # MessagesController#deliver_webhooks_to_bots. Callable from any Ractor.
  #
  # The `messages:` append itself is HTML the room views own; a bot reply made
  # by the :webhook job is appended through Delivery.broadcast_create, which
  # calls `Campfire::MessageBroadcasts.append(db, room, message)` when the room
  # side defines it.
  module Delivery
    CONNECTION_TTL = 60 # Membership::Connectable::CONNECTION_TTL

    ACTIVE_BOTS_IN_ROOM = "SELECT u.id FROM users u JOIN memberships m ON m.user_id = u.id " \
      "WHERE m.room_id = ? AND u.role = 2 AND u.status = 0 AND u.id != ? ORDER BY m.id"
    ACTIVE_BOTS_AMONG = "SELECT u.id FROM users u JOIN memberships m ON m.user_id = u.id " \
      "WHERE m.room_id = ? AND u.role = 2 AND u.status = 0 AND u.id != ? AND u.id IN (SELECT value FROM json_each(?)) ORDER BY u.id"
    HAS_WEBHOOK = "SELECT 1 FROM webhooks WHERE user_id = ? LIMIT 1"

    module_function

    # Membership.disconnected: connected_at nil or older than CONNECTION_TTL.
    def disconnected_cutoff(now = Time.now) = Clock.from_time(now - CONNECTION_TTL)

    # Room#receive: push_later. unread_memberships is a trigger on the message insert
    # (db/triggers.sql), so it is already in the message's commit.
    def receive(room, message) = Jobs.later(:push_message, room.id, message.id)

    # Message::Broadcasts#broadcast_create.
    def broadcast_create(db, room, message)
      if Campfire.const_defined?(:MessageBroadcasts) && MessageBroadcasts.respond_to?(:append)
        MessageBroadcasts.append(db, room, message)
      end
      broadcast_unread_room(db, room)
    end

    # Message::Broadcasts#broadcast_unread_room: {"roomId":id} to each member.
    def broadcast_unread_room(db, room)
      json = Cable::Frames.encode_message({ roomId: room.id })
      room.user_ids(db).each { |uid| Bus.publish([:cable, Cable.user_unreads_stream(uid), json].freeze) }
    end

    # MessagesController#deliver_webhooks_to_bots: in a direct room every
    # active bot member, elsewhere the mentioned ones (message.mentionees are
    # room members); never the author; only bots with a webhook.
    def deliver_webhooks(db, room, message)
      ids =
        if room.direct?
          db.query_splat(ACTIVE_BOTS_IN_ROOM, room.id, message.creator_id)
        else
          mentioned = mentioned_user_ids(db, message.body)
          mentioned.empty? ? [] : db.query_splat(ACTIVE_BOTS_AMONG, room.id, message.creator_id, JSON.generate(mentioned))
        end
      ids.each { |bot_id| Jobs.later(:webhook, bot_id, message.id) if db.query_single_splat(HAS_WEBHOOK, bot_id) }
      ids
    end

    # Message#plain_text_body with mentions resolved ("@Name", as ActionText
    # renders a User attachable), falling back to the attachment's filename.
    def plain_text_body(db, message)
      text = message.body ? (RichText.plain_text(message.body, resolver: Message.user_resolver(db)) rescue nil) : nil
      text.nil? || text.strip.empty? ? (message.attachment&.filename || "") : text
    end

    # Message::Mentionee#mentioned_users (ids, in document order).
    def mentioned_user_ids(db, body)
      return [] if body.nil? || body.empty?
      RichText.mentioned_user_ids(body, resolver: Message.user_resolver(db), verifier: sgid_verifier)
    rescue RichText::Error
      []
    end

    def sgid_verifier
      Ractor[:delivery_sgid_verifier] ||= RichText::SGID::Verifier.new(Campfire.config.secret_key_base)
    end
  end
end
