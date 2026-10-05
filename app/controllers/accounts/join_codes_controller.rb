# frozen_string_literal: true

module Campfire
  module Accounts
    class JoinCodesController < ApplicationController
      def before_action = ensure_can_administer

      def create
        account.reset_join_code!(@db)
        redirect_to("/account/edit")
      end
    end
  end
end
