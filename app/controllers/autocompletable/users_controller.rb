# frozen_string_literal: true

require "cgi/escape"

module Campfire
  module Autocompletable
    class UsersController < ApplicationController
      def index
        query = AutocompletableUsers.presence(params["filter"]) || AutocompletableUsers.presence(params["query"])
        room_id = nil
        if AutocompletableUsers.presence(params["room_id"])
          # Current.user.rooms.find(params[:room_id])
          room = Room.find_for_user(@db, current_user.id, params["room_id"].to_i) or not_found!
          room_id = room.id
        end
        page = AutocompletableUsers.page_number(params["page"])
        users = AutocompletableUsers.page(@db, room_id, query, page)

        if wants_json?
          total = AutocompletableUsers.count(@db, room_id, query)
          add_header("x-total-count", total.to_s)
          add_header("link", next_page_link(page + 1)) if page * AutocompletableUsers::PER_PAGE < total
          json(autocompletable_users_json(users))
        else
          html { autocompletable_users_index(users: users) }
        end
      end

      private

      # Addressable query_values= merge("page" => n): keys sorted.
      def next_page_link(next_page)
        q = query.merge("page" => next_page.to_s)
        qs = q.keys.sort.map { |k| "#{CGI.escape(k)}=#{CGI.escape(q[k].to_s)}" }.join("&")
        "<#{base_url}#{@request.path.split("?", 2).first}?#{qs}>; rel=\"next\""
      end
    end
  end
end
