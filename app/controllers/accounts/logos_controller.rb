# frozen_string_literal: true

module Campfire
  module Accounts
    class LogosController < ApplicationController
      allow_unauthenticated_access only: %i[show]
      CACHE_CONTROL = "max-age=300, public, stale-while-revalidate=604800"

      # include ActiveStorage::Streaming (ActionController::Live)
      def live_response? = true

      def before_action
        ensure_can_administer if @action == :destroy
      end

      def show
        a = account
        if a
          etag = ConditionalGet.etag("accounts", a.id, a.updated_at)
          add_header("etag", etag)
          return head(304) if ConditionalGet.fresh?(header("if-none-match"), etag)
        end
        add_header("cache-control", CACHE_CONTROL)
        small = params["size"] == "small"
        if a && (blob = Storage.attached(@db, "Account", a.id, "logo")) && (path = Storage.variant_path_for(@db, blob, small ? :small : :large))
          send_inline(File.binread(path), File.basename(path), "image/png")
        else
          name = small ? "app-icon-192.png" : "app-icon.png"
          send_inline(Assets.file(Assets.path("logos/#{name}")).body, name, "image/png")
        end
      end

      def destroy
        a = account
        Storage.detach(@db, "Account", a.id, "logo")
        redirect_to("/account/edit")
      end

      private

      def send_inline(bytes, filename, type)
        add_header("content-disposition", ConditionalGet.content_disposition(filename))
        add_header("content-transfer-encoding", "binary")
        text(bytes, 200, type)
      end
    end
  end
end
