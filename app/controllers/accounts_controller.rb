# frozen_string_literal: true

module Campfire
  class AccountsController < ApplicationController
    PER_PAGE = 500

    def before_action
      ensure_can_administer if @action == :update
      @account = account
    end

    def edit
      users = current_user.can_administer? ?
        User.account_users(@db, include_banned: true) : User.account_users(@db, include_banned: false)
      @administrators, @members = users.partition(&:administrator?)
      @last_page = users.size <= PER_PAGE
      @page_title = "Account settings"
      @nav = -> { _accounts_edit_nav }
      @footer = -> { _accounts_footer }
      html { frame_or_application_layout { accounts_edit } }
    end

    def update
      attrs = params["account"]
      attrs = {} unless attrs.is_a?(Hash)
      logo = attrs["logo"]
      @account.update!(@db, attrs.slice("name", "settings"))
      AccountsController.attach_logo(@db, @account, logo) if logo.is_a?(Multipart::UploadedFile)
      redirect_to("/account/edit", notice: "✓")
    end

    # has_one_attached :logo assignment (the account is touched, which moves
    # the logo ETag and ?v= cache buster).
    def self.attach_logo(db, account, upload)
      # Copy and checksum the file before taking the write lock.
      staged = File.open(upload.path, "rb") { |io| Storage.stage_upload(upload.filename, upload.content_type, io) }
      Storage.transaction(db) do
        b = staged.insert(db)
        Storage.attach(db, b.id, "Account", account.id, "logo")
        account.touch_only!(db)
        b
      end
    ensure
      staged&.discard
      upload.unlink
    end
  end
end
