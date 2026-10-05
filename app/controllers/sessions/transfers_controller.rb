# frozen_string_literal: true

module Campfire
  module Sessions
    class TransfersController < ApplicationController
      allow_unauthenticated_access

      def show
        html { layout { sessions_transfers_show(action: @path) } }
      end

      # User.active.find_by_transfer_id(params[:id]) (find_signed purpose: :transfer)
      def update
        id = Campfire.secrets.verify_signed_id(params["id"].to_s, model_name: "User", purpose: "transfer")
        user = id && User.find(@db, id)
        if user&.active?
          start_new_session_for(user)
          redirect_to(post_authenticating_url)
        else
          head(400)
        end
      end
    end
  end
end
