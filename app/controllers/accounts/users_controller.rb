# frozen_string_literal: true

module Campfire
  module Accounts
    class UsersController < ApplicationController
      PER_PAGE = 500

      def before_action
        return if @action == :index
        ensure_can_administer
        @user = User.find_active(@db, params["user_id"] || params["id"]) or not_found!
      end

      # Always a turbo stream (the page's lazy next_page_container frame).
      def index
        users = User.active_ordered(@db, without_bots: true)
        page = params["page"].to_s.to_i
        page = 1 if page < 1
        page_count = [(users.size + PER_PAGE - 1) / PER_PAGE, 1].max
        records = users[(page - 1) * PER_PAGE, PER_PAGE] || []
        last = page == page_count
        turbo_stream do
          @b << '<turbo-stream action="replace" target="next_page_container"><template>'
          admin_view = current_user.can_administer?
          records.each { |u| _accounts_users_user(user: u, admin_view: admin_view) }
          @b << "</template></turbo-stream>\n\n"
          unless last
            @b << '  <turbo-stream action="append" target="account_users"><template>'
            _accounts_users_next_page_container(page: page + 1)
            @b << "</template></turbo-stream>\n"
          end
        end
      end

      def update
        u = params["user"]
        role = u.is_a?(Hash) ? u["role"] : nil
        role = "member" unless role == "member" || role == "administrator"
        @user.update_role!(@db, role)
        redirect_to("/account/edit")
      end

      def destroy
        @user.deactivate!(@db)
        redirect_to("/account/edit")
      end
    end
  end
end
