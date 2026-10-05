# frozen_string_literal: true

module Campfire
  module Users
    class BansController < ApplicationController
      def before_action
        ensure_can_administer
        @user = User.find(@db, params["user_id"].to_s.to_i) or not_found!
      end

      def create
        @user.ban!(@db)
        redirect_to("/users/#{@user.id}")
      end

      def destroy
        @user.unban!(@db)
        redirect_to("/users/#{@user.id}")
      end
    end
  end
end
