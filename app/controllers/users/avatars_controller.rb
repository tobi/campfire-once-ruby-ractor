# frozen_string_literal: true

module Campfire
  module Users
    class AvatarsController < ApplicationController
      CACHE_CONTROL = "max-age=1800, public, stale-while-revalidate=604800"
      SVG = "image/svg+xml; charset=utf-8"

      # include ActiveStorage::Streaming (ActionController::Live)
      def live_response? = true

      def show
        id = Campfire.secrets.verify_signed_id(params["user_id"].to_s, model_name: "User", purpose: "avatar")
        user = id && User.find(@db, id)
        unless user
          add_header("cache-control", "no-cache")
          return text("", 404, "text/html")
        end
        etag = ConditionalGet.etag("users", user.id, user.updated_at, ConditionalGet::AVATAR_TEMPLATE_DIGEST)
        add_header("etag", etag)
        return head(304) if ConditionalGet.fresh?(header("if-none-match"), etag)
        add_header("cache-control", CACHE_CONTROL)

        if (blob = Storage.attached(@db, "User", user.id, "avatar")) && (path = Storage.variant_path_for(@db, blob, :square))
          send_inline(File.binread(path), File.basename(path), "image/webp")
        elsif user.bot?
          send_inline(Assets.file(Assets.path("default-bot-avatar.svg")).body, "default-bot-avatar.svg", "image/svg+xml")
        else
          @b = +""
          users_avatars_show(user: user)
          text(@b, 200, SVG)
        end
      end

      def destroy
        Storage.detach(@db, "User", current_user.id, "avatar")
        redirect_to("/users/me/profile")
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
