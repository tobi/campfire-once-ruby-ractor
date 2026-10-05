# frozen_string_literal: true

require "cgi/escape"

module Campfire
  class UsersController < ApplicationController
    allow_unauthenticated_access only: %i[new create]

    def before_action
      case @action
      when :new, :create
        # require_unauthenticated_access: restore_authentication, redirect_signed_in_user_to_root
        if restore_authentication
          redirect_to("/")
          throw :halt
        end
        # verify_join_code
        unless account && account.join_code == params["join_code"]
          head(404)
          throw :halt
        end
      when :show
        @user = User.find(@db, params["id"].to_i) or not_found!
      end
    end

    def new
      @page_title = "Sign up"
      @body_class = "signup"
      @nav = -> { _users_new_nav }
      join_code = params["join_code"]
      html { layout { users_new(join_code: join_code) } }
    end

    def create
      attrs = params["user"]
      attrs = {} unless attrs.is_a?(Hash)
      email = attrs["email_address"]
      if (id = Login.create_user!(@db, scalar(attrs["name"]), scalar(email), scalar(attrs["password"])))
        user = User.find(@db, id)
        Accounts::BotsController.attach_avatar(@db, user, attrs["avatar"]) if attrs["avatar"]
        start_new_session_for(user)
        redirect_to("/")
      else
        # new_session_url(email_address: ...)
        redirect_to("/session/new?email_address=#{CGI.escape(email.to_s)}")
      end
    end

    def show
      user = @user
      @page_title = user.name
      @nav = -> { _users_show_nav(user: user) }
      html { layout { users_show(user: user) } }
    end

    private

    def scalar(v) = v.is_a?(String) ? v : nil
  end
end
