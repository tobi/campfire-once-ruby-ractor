# frozen_string_literal: true

module Campfire
  class FirstRunsController < ApplicationController
    allow_unauthenticated_access

    # FirstRun::ACCOUNT_NAME / FIRST_ROOM_NAME
    ACCOUNT_NAME = "Campfire"
    FIRST_ROOM_NAME = "All Talk"

    def before_action
      # prevent_repeats
      if @db.query_single_splat("SELECT 1 FROM accounts LIMIT 1".freeze)
        redirect_to("/")
        throw :halt
      end
    end

    def show
      @page_title = "Set up Campfire"
      @body_class = "signup"
      html { layout { first_runs_show } }
    end

    def create
      attrs = params["user"]
      attrs = {} unless attrs.is_a?(Hash)
      str = ->(v) { v.is_a?(String) ? v : nil }
      user = FirstRun.create!(@db, str.(attrs["name"]), str.(attrs["email_address"]), str.(attrs["password"]))
      if user
        Accounts::BotsController.attach_avatar(@db, user, attrs["avatar"]) if attrs["avatar"]
        start_new_session_for(user)
      end
      redirect_to("/")
    end
  end

  # FirstRun.create!: the account, the first open room created by the new
  # administrator, and their membership of it.
  module FirstRun
    module_function

    def create!(db, name, email, password, now: Clock.now_db)
      db.transaction do
        db.execute("INSERT INTO accounts (name, join_code, created_at, updated_at) VALUES (?, ?, ?, ?)".freeze,
          FirstRunsController::ACCOUNT_NAME, Account.generate_join_code, now, now)
        id = Login.create_user!(db, name, email, password, role: 1, now: now) or return nil
        db.execute("INSERT INTO rooms (name, type, creator_id, created_at, updated_at) VALUES (?, 'Rooms::Open', ?, ?, ?)".freeze,
          FirstRunsController::FIRST_ROOM_NAME, id, now, now)
        RoomOps.grant_open_rooms_to(db, id, now)
        User.find(db, id)
      end
    end
  end
end
