# frozen_string_literal: true

module Campfire
  module Accounts
    class CustomStylesController < ApplicationController
      def before_action
        ensure_can_administer
        @account = account
      end

      def edit
        @page_title = "Custom styles"
        @nav = -> { _accounts_bots_nav(back: "/account/edit") }
        html { frame_or_application_layout { accounts_custom_styles_edit } }
      end

      def update
        a = params["account"]
        unless a.is_a?(Hash)
          head(400)
          throw :halt
        end
        @account.update!(@db, a.slice("custom_styles"))
        redirect_to("/account/custom_styles/edit", notice: "✓")
      end
    end
  end
end
