# frozen_string_literal: true

require "cgi/escape"

module Campfire
  class SearchesController < ApplicationController
    def index
      user_id = current_user.id
      raw = params["q"]
      raw = nil unless raw.is_a?(String)
      q = Search.sanitize(raw)
      query = Search.present?(q) ? q : nil
      page = query ? Search.messages(@db, user_id, query) : nil
      recent = Search.recent(@db, user_id)
      room = last_room_visited

      @page_title = "Search"
      @body_class = "sidebar searches"
      @nav = -> { _searches_nav(query: query, count: page ? page.size : 0, recent: recent) }
      @footer = -> { _searches_footer(q: raw, room_id: room.id) }
      @sidebar = -> { _searches_sidebar(recent: recent) }
      html { layout { searches_index(page: page) } }
    end

    def create
      query = Search.sanitize(params["q"])
      Search.record(@db, current_user.id, query)
      redirect_to("/searches?q=#{CGI.escape(query.to_s)}")
    end

    def clear
      Search.clear(@db, current_user.id)
      redirect_to("/searches")
    end
  end
end
