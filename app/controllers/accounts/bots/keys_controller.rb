# frozen_string_literal: true

module Campfire
  module Accounts
    module Bots
      class KeysController < ApplicationController
        def before_action = ensure_can_administer

        def update
          bot = User.find_active_bot(@db, params["bot_id"]) or not_found!
          bot.reset_bot_key!(@db)
          redirect_to("/account/bots")
        end
      end
    end
  end
end
