# frozen_string_literal: true

require "securerandom"

module Campfire
  module Users
    module PushSubscriptions
      class TestNotificationsController < ApplicationController
        def create
          sub = PushSubscription.find_for_user(@db, current_user.id, params["push_subscription_id"]) or not_found!
          Jobs.later(:push_test_notification, sub.id, "Campfire Test", SecureRandom.uuid, "#{base_url}/users/me/push_subscriptions") if Jobs::HANDLERS.key?(:push_test_notification)
          redirect_to("/users/me/push_subscriptions")
        end
      end
    end
  end
end
