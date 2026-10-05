# frozen_string_literal: true

require_relative "delivery"

module Campfire
  # Room::PushMessageJob + Room::MessagePusher + WebPush::Pool: Jobs.later(:push_message, room_id, message_id).
  module PushMessageJob
    CONCURRENCY = 50 # WebPush::Pool's delivery threads

    SUBSCRIPTION_COLS = "ps.id, ps.user_id, ps.endpoint, ps.p256dh_key, ps.auth_key"
    # relevant_subscriptions: visible, disconnected memberships of the room, not the author.
    RELEVANT = "FROM push_subscriptions ps JOIN memberships m ON m.user_id = ps.user_id " \
      "WHERE m.room_id = ? AND m.involvement != 'invisible' AND (m.connected_at IS NULL OR m.connected_at < ?) AND m.user_id != ?"
    EVERYTHING = "SELECT #{SUBSCRIPTION_COLS} #{RELEVANT} AND m.involvement = 'everything' ORDER BY ps.id"
    MENTIONS = "SELECT #{SUBSCRIPTION_COLS} #{RELEVANT} AND m.involvement = 'mentions' " \
      "AND ps.user_id IN (SELECT value FROM json_each(?)) ORDER BY ps.id"
    # user.memberships.unread.count
    BADGE = "SELECT COUNT(*) FROM memberships WHERE user_id = ? AND unread_at IS NOT NULL"
    DELETE = "DELETE FROM push_subscriptions WHERE id = ?"

    Payload = Data.define(:title, :body, :path)

    module_function

    def perform(room_id, message_id)
      db = DB.connection
      room = Room.find(db, room_id) or return
      message = Message.load_one(db, message_id) or return
      payload = payload(db, room, message)
      cutoff = Delivery.disconnected_cutoff
      subs = db.query_array(EVERYTHING, room.id, cutoff, message.creator_id)
      mentioned = Delivery.mentioned_user_ids(db, message.body)
      subs.concat(db.query_array(MENTIONS, room.id, cutoff, message.creator_id, JSON.generate(mentioned))) unless mentioned.empty?
      deliver_all(db, payload, subs)
    end

    # MessagePusher#build_payload
    def payload(db, room, message)
      path = "/rooms/#{room.id}"
      text = Delivery.plain_text_body(db, message)
      if room.direct?
        Payload.new(message.creator_name, text, path)
      else
        Payload.new(room.name, "#{message.creator_name}: #{text}", path)
      end
    end

    # WebPush::Pool#queue: one delivery per subscription, concurrently.
    def deliver_all(db, payload, subs)
      return 0 if subs.empty?
      vapid = WebPush.vapid
      badges = {}
      Sync do |task|
        gate = Async::Semaphore.new(CONCURRENCY, parent: task)
        subs.map do |id, user_id, endpoint, p256dh, auth|
          badge = (badges[user_id] ||= db.query_single_splat(BADGE, user_id))
          message = WebPush.encoded_message(payload.title, payload.body, payload.path, badge)
          gate.async { deliver(db, id, endpoint, p256dh, auth, message, vapid) }
        end.each(&:wait)
      end
      subs.size
    end

    # WebPush::Pool#deliver: an expired subscription (410) or a key OpenSSL
    # rejects is destroyed; other failures are logged.
    def deliver(db, id, endpoint, p256dh, auth, message, vapid)
      ip = WebPush.resolve_endpoint_ip(endpoint) or return
      WebPush.deliver(endpoint, ip, p256dh, auth, message, vapid: vapid)
    rescue WebPush::ExpiredSubscription, OpenSSL::OpenSSLError
      db.execute(DELETE, id)
      nil
    rescue => e
      Log.error("Error in WebPush deliver", e)
      nil
    end
  end

  # Users::PushSubscriptions::TestNotificationsController#create:
  # Jobs.call(:push_test, user_id, subscription_id, url). Returns :delivered,
  # :skipped (endpoint not deliverable) or :not_found; raises (Jobs.call -> nil)
  # when the push service fails, as the synchronous upstream deliver does.
  module PushTestJob
    TITLE = "Campfire Test"

    module_function

    def perform(user_id, subscription_id, url)
      db = DB.connection
      sub = PushSubscription.find_for_user(db, user_id, subscription_id) or return :not_found
      ip = WebPush.resolve_endpoint_ip(sub.endpoint) or return :skipped
      badge = db.query_single_splat(PushMessageJob::BADGE, user_id)
      message = WebPush.encoded_message(TITLE, SecureRandom.uuid, url, badge)
      WebPush.deliver(sub.endpoint, ip, sub.p256dh_key, sub.auth_key, message)
      :delivered
    end
  end

  # The shape Users::PushSubscriptions::TestNotificationsController enqueues:
  # Jobs.later(:push_test_notification, subscription_id, title, body, url)
  # (the controller has already scoped the subscription to Current.user).
  module PushTestNotificationJob
    module_function

    def perform(subscription_id, title, body, url)
      db = DB.connection
      row = db.query_single_array("SELECT user_id, endpoint, p256dh_key, auth_key FROM push_subscriptions WHERE id = ?".freeze, subscription_id) or return :not_found
      user_id, endpoint, p256dh, auth = row
      ip = WebPush.resolve_endpoint_ip(endpoint) or return :skipped
      message = WebPush.encoded_message(title, body, url, db.query_single_splat(PushMessageJob::BADGE, user_id))
      WebPush.deliver(endpoint, ip, p256dh, auth, message)
      :delivered
    end
  end

  Jobs.register(:push_message, PushMessageJob)
  Jobs.register(:push_test, PushTestJob)
  Jobs.register(:push_test_notification, PushTestNotificationJob)
end
