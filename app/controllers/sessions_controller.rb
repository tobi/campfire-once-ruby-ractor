# frozen_string_literal: true

module Campfire
  class SessionsController < ApplicationController
    allow_unauthenticated_access only: %i[new create]

    REJECTION = "Too many requests or unauthorized."
    DESTROY_PUSH_SUBSCRIPTION_SQL = "DELETE FROM push_subscriptions WHERE endpoint = ? AND user_id = ?".freeze

    def before_action
      # rate_limit to: 10, within: 3.minutes, only: :create (by request.remote_ip)
      if @action == :create && Login.rate_limited?(remote_ip)
        render_rejection(429)
        throw :halt
      end
    end

    def new
      # before_action :ensure_user_exists
      return redirect_to("/first_run") unless @db.query_single_splat("SELECT 1 FROM users LIMIT 1".freeze)
      render_new
    end

    def create
      if (id = Login.authenticate(@db, params["email_address"], params["password"])) && (user = User.find(@db, id))
        start_new_session_for(user)
        redirect_to(post_authenticating_url)
      else
        render_rejection(401)
      end
    end

    def destroy
      if (endpoint = params["push_subscription_endpoint"])
        @db.execute(DESTROY_PUSH_SUBSCRIPTION_SQL, endpoint.to_s, current_user.id)
      end
      terminate_current_session
      redirect_to("/")
    end

    private

    def render_new(status = 200)
      @page_title = "Sign in"
      @head = TURBO_RELOAD_META
      email = params["email_address"]
      email = nil unless email.is_a?(String)
      html(status) { layout { sessions_new(email: email) } }
    end

    # flash.now[:alert] = ...; render :new, status:
    def render_rejection(status)
      flash
      @flash = @flash.merge("alert" => REJECTION)
      render_new(status)
    end
  end
end
