# frozen_string_literal: true

module Campfire
  # A bot's webhook (upstream Webhook). Delivery runs in a job handler
  # (Jobs.later(:webhook, bot_id, message_id)); this is the record.
  class Webhook < Struct.new(:id, :user_id, :url, :created_at, :updated_at)
    COLS = "id, user_id, url, created_at, updated_at"
    ENDPOINT_TIMEOUT = 7

    def self.for_user(db, user_id)
      row = db.query_single_array("SELECT #{COLS} FROM webhooks WHERE user_id = ? ORDER BY id LIMIT 1".freeze, user_id)
      row && new(*row)
    end
  end
end
