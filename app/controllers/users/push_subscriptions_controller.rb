# frozen_string_literal: true

module Campfire
  module Users
    class PushSubscriptionsController < ApplicationController
      def index
        @push_subscriptions = PushSubscription.for_user(@db, current_user.id)
        @page_title = "Push notification subscriptions"
        @nav = -> { _rooms_nav_back }
        html { frame_or_application_layout { users_push_subscriptions_index } }
      end

      def create
        ps = params["push_subscription"]
        return head(400) unless ps.is_a?(Hash)
        endpoint, p256dh, auth = ps["endpoint"], ps["p256dh_key"], ps["auth_key"]
        if (sub = PushSubscription.find_by_keys(@db, current_user.id, endpoint, p256dh, auth))
          # Existing endpoints must pass current validations
          if sub.valid?
            sub.touch!(@db)
            head(200)
          else
            head(422)
          end
        elsif PushSubscription.valid_endpoint?(endpoint)
          PushSubscription.create!(@db, current_user.id, endpoint, p256dh, auth, header("user-agent")&.to_s)
          head(200)
        else
          head(422)
        end
      end

      def destroy
        PushSubscription.destroy_for_user(@db, current_user.id, params["id"])
        redirect_to("/users/me/push_subscriptions")
      end
    end
  end
end
