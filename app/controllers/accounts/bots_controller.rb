# frozen_string_literal: true

module Campfire
  module Accounts
    class BotsController < ApplicationController

      def before_action
        ensure_can_administer
        if @action == :edit || @action == :update || @action == :destroy
          @bot = User.find_active_bot(@db, params["id"])
          unless @bot
            text(Assets.file("/404.html")&.body || "Not Found", 404, "text/html; charset=UTF-8")
            throw :halt
          end
        end
      end

      def index
        @bots = User.active_bots(@db)
        @page_title = "Chat bots"
        @nav = -> { _accounts_bots_nav(back: "/account/edit") }
        html { frame_or_application_layout { accounts_bots_index } }
      end

      def new
        @page_title = "New chat bot"
        @nav = -> { _accounts_bots_nav(back: "/account/bots") }
        html { frame_or_application_layout { accounts_bots_new } }
      end

      def create
        attrs = bot_params
        bot = User.create_bot!(@db, name: attrs["name"], webhook_url: attrs["webhook_url"])
        BotsController.attach_avatar(@db, bot, attrs["avatar"])
        redirect_to("/account/bots")
      end

      def edit
        @webhook_url = @bot.webhook_url(@db)
        @avatar_blob = Storage.attached(@db, "User", @bot.id, "avatar")
        @page_title = "Edit bot"
        @nav = -> { _accounts_bots_nav(back: "/account/bots") }
        html { frame_or_application_layout { accounts_bots_edit } }
      end

      def update
        attrs = bot_params
        @bot.update_bot!(@db, name: attrs["name"], webhook_url: attrs["webhook_url"])
        BotsController.attach_avatar(@db, @bot, attrs["avatar"])
        redirect_to("/account/bots")
      end

      def destroy
        @bot.deactivate!(@db)
        redirect_to("/account/bots")
      end

      # has_one_attached :avatar assignment (touches the user: avatar ETag/?v=).
      def self.attach_avatar(db, user, upload)
        return unless upload.is_a?(Multipart::UploadedFile)
        # Copy and checksum the file before taking the write lock.
        staged = File.open(upload.path, "rb") { |io| Storage.stage_upload(upload.filename, upload.content_type, io) }
        Storage.transaction(db) do
          b = staged.insert(db)
          Storage.attach(db, b.id, "User", user.id, "avatar")
          user.touch!(db)
        end
      ensure
        staged&.discard
        upload&.unlink if upload.is_a?(Multipart::UploadedFile)
      end

      private

      def bot_params
        u = params["user"]
        unless u.is_a?(Hash)
          head(400)
          throw :halt
        end
        u
      end
    end
  end
end
