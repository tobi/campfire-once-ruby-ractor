# frozen_string_literal: true

require "cgi/escape"

module Campfire
  # SearchesHelper plus the search page's recent-search links and results.
  module Helpers
    # searches_path(q: query): Hash#to_query escaping (CGI.escape), memoized
    # per query so recent-search links don't re-escape on every render.
    def search_query_path(query)
      @b << Cache.fetch(:search_query_path, query) { ERB::Escape.html_escape("/searches?q=" + CGI.escape(query)).freeze }
      nil
    end

    def recent_search_links(recent)
      recent.each do |q|
        @b << '      <a class="align-center gap room btn txt-nowrap" href="'
        search_query_path(q)
        @b << "\">\n        <span class=\"overflow-ellipsis\">“"
        h(q)
        @b << "”</span>\n</a>"
      end
      nil
    end

    def recent_searches_clear_button(recent)
      return nil if recent.empty?
      @b << "      "
      clear_searches_button
    end

    # button_to clear_searches_url, method: :delete (absolute URL, per-form token).
    def clear_searches_button
      @b << '<form class="button_to" method="post" action="'
      h(base_url)
      @b << '/searches/clear"><input type="hidden" name="_method" value="delete" /><button class="btn searches__btn" data-turbo-confirm="Are you sure you want to clear your recent searches?" type="submit">' \
        "\n        <img aria-hidden=\"true\" src=\"" << Assets.path("broom.svg") << "\" />\n        <span class=\"for-screen-reader\">Clear recent searches</span>\n</button>"
      hidden_per_form_token("/searches/clear", "delete")
      @b << "</form>"
      nil
    end

    # render partial: "messages/message", collection: @messages, cached: true.
    # Same fragments as room pages (cache [message, "presentation-v3"]); each
    # miss renders with its own room's display name.
    def render_search_messages(page)
      n = page ? page.size : 0
      # search_results_tag's capture: a blank buffer collapses to "\n".
      @b << "\n"
      return nil if n.zero?
      @b << "    "
      ids = page.ids
      versions = page.versions
      misses = nil
      i = 0
      while i < n
        (misses ||= []) << ids[i] unless Cache.peek_fragment(:message, ids[i], versions[i])
        i += 1
      end
      loaded = misses && Message.load_presentation(@db, misses)
      names = nil
      i = 0
      while i < n
        if (f = Cache.peek_fragment(:message, ids[i], versions[i]))
          PageParts.record(@b, f)
          @b << f
        elsif loaded && (m = loaded[ids[i]])
          names ||= {}
          name = names.fetch(m.room_id) { names[m.room_id] = (room = Room.find(@db, m.room_id)) ? room_display_name(room, nil) : nil }
          f = cached_message(m, name)
          PageParts.record(@b, f)
          @b << f
        end
        i += 1
      end
      @b << "\n"
      nil
    end
  end
end
