# frozen_string_literal: true

module Campfire
  # RoomsHelper (+ Rooms::InvolvementsHelper).
  module Helpers
    # room_display_name(room, for_user: Current.user). Direct rooms list the
    # other members (all members when for_user is nil), else for_user's name.
    def room_display_name(room, for_user = current_user)
      return room.name unless room.direct?
      names = room.user_names_except(@db, for_user&.id)
      names.empty? ? (for_user&.name || "") : to_sentence(names)
    end

    # room_display_name for the current user, memoized per request/room.
    def current_room_display_name(room)
      (@room_display_names ||= {})[room.id] ||= room_display_name(room)
    end

    # link_to_edit_room: [:edit, @room] -> /rooms/<opens|closeds|directs>/:id/edit
    def edit_room_path(room)
      +"/rooms/" << ROOM_PATH_SEGMENTS.fetch(room.type) << "/" << room.id_s << "/edit"
    end

    # room_messages_path(room): /rooms/:id/messages
    def room_messages_path(room) = +"/rooms/" << room.id_s << "/messages"

    ROOM_PATH_SEGMENTS = { "Rooms::Open" => "opens", "Rooms::Closed" => "closeds", "Rooms::Direct" => "directs" }.freeze

    def button_to_jump_to_newest_message
      @b << '<button class="message-area__return-to-latest btn" data-action="messages#returnToLatest" data-messages-target="latest" hidden="hidden"><img aria-hidden="true" src="' <<
        Assets.path("arrow-down.svg") << '" width="20" height="20" /><span class="for-screen-reader">Jump to newest message</span></button>'
      nil
    end

    HUMANIZE_INVOLVEMENT = {
      "mentions" => "Notifying about @ mentions",
      "everything" => "Notifying about all messages",
      "nothing" => "Notifications are off",
      "invisible" => "Notifications are off and room invisible in sidebar"
    }.freeze
    SHARED_INVOLVEMENT_ORDER = %w[mentions everything nothing invisible].freeze
    DIRECT_INVOLVEMENT_ORDER = %w[everything nothing].freeze

    def next_involvement_for(room, involvement)
      order = room.direct? ? DIRECT_INVOLVEMENT_ORDER : SHARED_INVOLVEMENT_ORDER
      order[(order.index(involvement) || -1) + 1] || order.first
    end

    # turbo_frame_for_involvement_tag(room) { ... }
    def turbo_frame_for_involvement_tag(room)
      @b << '<turbo-frame data-controller="turbo-frame" data-action="notifications:ready@window-&gt;turbo-frame#load" data-turbo-frame-url-param="/rooms/' <<
        room.id_s << '/involvement" id="involvement_' << room.dom_key << '">'
      yield
      @b << "</turbo-frame>"
      nil
    end

    # The pwa/_browser_settings, _system_settings and _install_instructions
    # partials of the bell's "not allowed" dialog: they depend only on the
    # user agent (platform) and base_url, so they are rendered once per
    # user agent and reused while base_url matches.
    def pwa_notification_help
      table = Cache.table(:pwa_notification_help)
      entry = table[user_agent]
      unless entry && entry[0] == base_url
        html = capture do
          _pwa_browser_settings
          @b << "\n            "
          _pwa_system_settings
          @b << "\n            "
          _pwa_install_instructions
        end
        table.clear if table.size >= Cache::LIMIT
        entry = table[user_agent] = [base_url, html.freeze].freeze
      end
      @b << entry[1]
      nil
    end

    # button_to_change_involvement(room, involvement)
    def button_to_change_involvement(room, involvement)
      action = "/rooms/#{room.id}/involvement?involvement=#{next_involvement_for(room, involvement)}"
      @b << '<form class="button_to" method="post" action="'
      h(action)
      @b << '"><input type="hidden" name="_method" value="put" /><button role="checkbox" aria-checked="true" aria-labelledby="involvement_label_' <<
        room.dom_key << '" tabindex="0" class="btn '
      h(involvement)
      @b << '" type="submit"><img aria-hidden="true" src="' << Assets.path("notification-bell-#{involvement}.svg") <<
        '" width="20" height="20" /><span class="for-screen-reader" id="involvement_label_' << room.dom_key << '">'
      h(HUMANIZE_INVOLVEMENT[involvement])
      @b << '</span></button><input type="hidden" name="authenticity_token" value="' << form_authenticity_token(action, "put") << '" /></form>'
      nil
    end
  end
end
