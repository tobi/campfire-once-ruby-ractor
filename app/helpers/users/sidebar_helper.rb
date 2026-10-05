# frozen_string_literal: true

module Campfire
  # Users::SidebarHelper plus the small shared bits the sidebar, search and
  # session pages need (avatar URLs, signed stream names, per-form CSRF).
  module Helpers
    ROOM_DOM_KEYS = { "Rooms::Open" => "rooms_open", "Rooms::Closed" => "rooms_closed", "Rooms::Direct" => "rooms_direct" }.freeze
    STREAM_SOURCE_OPEN = '<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="'
    STREAM_SOURCE_CLOSE = '"></turbo-cable-stream-source>'

    # sidebar_turbo_frame_tag(src:) opening tag. The action value is
    # html_safe upstream, so "->" is not escaped.
    def sidebar_turbo_frame_open(src = nil)
      @b << '<turbo-frame data-turbo-permanent="true" data-controller="rooms-list read-rooms turbo-frame" data-rooms-list-unread-class="unread" data-action="presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload" id="user_sidebar"'
      @b << ' src="' << src << '"' if src
      @b << ' target="_top">'
      nil
    end

    # turbo_stream_from :rooms / turbo_stream_from Current.user, :rooms
    def sidebar_stream_sources(user_id)
      @b << STREAM_SOURCE_OPEN << Cache.fetch(:signed_stream, "rooms") { Campfire.secrets.signed_stream_name("rooms") } << STREAM_SOURCE_CLOSE
      @b << "\n  " << STREAM_SOURCE_OPEN
      @b << Cache.fetch(:user_rooms_stream, user_id) {
        Campfire.secrets.signed_stream_name(RailsCompat::GID.build("User", user_id).to_param, "rooms")
      }
      @b << STREAM_SOURCE_CLOSE
      nil
    end

    # button_to's per-form authenticity token (action path + method), masked
    # once per request: repeated forms (sidebar placeholders) share the masked
    # value, which Rails accepts like any other mask of the same token.
    def per_form_token(action_path, method)
      by_path = ((@per_form_tokens ||= {})[method] ||= {})
      by_path[action_path] ||= begin
        csrf_token
        RailsCompat::CSRF.mask(RailsCompat::CSRF.per_form_token(RailsCompat::CSRF.raw_token(session["_csrf_token"]), action_path, method))
      end
    end

    def hidden_per_form_token(action_path, method)
      @b << '<input type="hidden" name="authenticity_token" value="' << per_form_token(action_path, method) << '" />'
      nil
    end

    def sidebar_directs(directs, user)
      directs.each { |item| sidebar_direct(item, user) }
      nil
    end

    def sidebar_direct_placeholders(user)
      Sidebar.each_placeholder_user(@db, user.id) { |id, name, updated_at| sidebar_direct_placeholder(id, name, updated_at) }
      nil
    end

    # users/sidebars/rooms/_direct, cached by membership like `cache membership`.
    def sidebar_direct(item, user)
      @b << Cache.fragment(:sidebar_direct, item.membership_id, item.membership_updated_at) {
        outer = @b
        @b = String.new(capacity: 2048, encoding: Encoding::UTF_8)
        begin
          members = []
          Sidebar.each_member(@db, item.room_id, user.id) { |id, name, updated_at| members << [id, name, updated_at] }
          members << [user.id, user.name, user.updated_at] if members.empty?
          _users_sidebars_rooms_direct(item: item, members: members)
          @b
        ensure
          @b = outer
        end
      }
      nil
    end

    # users/sidebars/rooms/_direct_placeholder: the button is cached per user
    # (it depends only on id, name and updated_at); the token is per render.
    def sidebar_direct_placeholder(id, name, updated_at)
      @b << Cache.fragment(:sidebar_placeholder, id, updated_at) {
        outer = @b
        @b = String.new(capacity: 1024, encoding: Encoding::UTF_8)
        begin
          _users_sidebars_rooms_direct_placeholder(id: id, name: name, updated_at: updated_at)
          @b
        ensure
          @b = outer
        end
      }
      hidden_per_form_token("/rooms/directs", "post")
      @b << "</form>"
      nil
    end

    # users/sidebars/rooms/_shared (link_to_room with list id and sort name).
    # id may be the Integer or its text (Sidebar::Item#room_id_s).
    def sidebar_shared(id, name, type, unread)
      id = id.to_s unless id.is_a?(String)
      @b << '<a id="list_' << ROOM_DOM_KEYS.fetch(type) << "_" << id
      @b << '" data-rooms-list-target="room" data-room-id="' << id
      @b << '" data-badge-dot-target="unread" data-sorted-list-target="item"'
      @b << ' data-sorted-list-name="' << ERB::Escape.html_escape(name) << '"' unless name.nil?
      @b << (unread ? ' style="--column-gap: 0.5em" class="align-center gap room btn txt-nowrap unread" href="/rooms/' : ' style="--column-gap: 0.5em" class="align-center gap room btn txt-nowrap" href="/rooms/')
      @b << id << "\">\n  <span class=\"overflow-ellipsis\">"
      @b << ERB::Escape.html_escape(name) unless name.nil?
      @b << "</span>\n</a>"
      nil
    end

    # name.split(" ")[0]
    def first_word(name)
      return nil if name.nil?
      s = name.lstrip
      i = s.index(/\s/)
      i ? s[0, i] : (s.empty? ? nil : s)
    end
  end
end
