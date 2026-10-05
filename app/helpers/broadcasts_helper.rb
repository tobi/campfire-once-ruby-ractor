# frozen_string_literal: true

module Campfire
  # Turbo Streams: <turbo-cable-stream-source> tags, <turbo-stream> builders
  # (turbo-rails' turbo_stream_action_tag serialization) and broadcasts.
  #
  #   turbo_stream_from(room, "messages", channel: "RoomMessagesChannel")
  #   turbo_stream_tag("append", "messages_rooms_open_1", html)   # => String
  #   turbo_stream_tag("replace", target, html, maintain_scroll: true)
  #   turbo_stream_tag("remove", target)
  #   broadcast_to(room_stream(room), html)  # Cable.broadcast on the *unsigned* name
  #
  # Streams are named like Rails' broadcasting names (`room_stream(room)` is
  # "<room GID param>:messages"); subscribers get them by signed name, which
  # RoomMessagesChannel verifies before stream_from.
  module Helpers
    def turbo_stream_from(room, name, channel: "Turbo::StreamsChannel")
      @b << '<turbo-cable-stream-source channel="' << channel << '" signed-stream-name="' <<
        signed_room_stream_name(room, name) << '"></turbo-cable-stream-source>'
      nil
    end

    # Deterministic; cached per (room, name).
    def signed_room_stream_name(room, name = "messages")
      Cache.fetch(:signed_room_stream, "#{room.type}:#{room.id}:#{name}") do
        Campfire.secrets.signed_stream_name(room.gid_param, name.to_s).freeze
      end
    end

    # broadcasting name for (room, :messages)
    def room_stream(room) = Cable.room_messages_stream(room.type, room.id)

    # turbo_stream_action_tag(action, target:, template:, **attributes):
    # attributes come before action/target; true renders as "true".
    def turbo_stream_tag(action, target, html = nil, **attributes)
      s = +"<turbo-stream"
      attributes.each { |k, v| s << " " << k.to_s << '="' << ERB::Escape.html_escape(v.to_s) << '"' }
      s << ' action="' << action << '" target="' << ERB::Escape.html_escape(target) << '">'
      s << "<template>" << html.to_s << "</template>" unless action == "remove" || action == "refresh"
      s << "</turbo-stream>"
    end

    def broadcast_to(stream, payload)
      Cable.broadcast(stream, payload)
    end
  end
end

module Campfire
  # Message::Broadcasts rendering. Rails renders broadcasts with
  # ApplicationController.renderer: no session, so forms carry no token; URLs
  # use the request host without port (SetCurrentRequest) inside a request and
  # http://example.org from jobs (bot replies through Delivery.broadcast_create).
  # Those renders fill the fragment cache, so pages reuse them verbatim.
  module MessageBroadcasts
    class Renderer
      include Helpers
      include Views

      HOST = "example.org"
      BASE_URL = "http://example.org"

      # Inside a request Current.request is set, so SetCurrentRequest's
      # default_url_options give the request host (no port) and protocol.
      def initialize(db, host = HOST, base_url = BASE_URL)
        @db = db
        @b = nil
        @host = host
        @base_url = base_url
      end

      def host_with_port = @host
      def base_url = @base_url
      def current_user = nil
      def path = "/"

      # The renderer's request has no session, so protect_against_forgery? is
      # false and forms carry no authenticity_token.
      def form_authenticity_token(_action, _method) = nil

      def message_html(room, message)
        cached_message(message.context!(host_without_port, user_resolver), room_display_name(room, nil))
      end
    end

    module_function

    # broadcast_append_to room, :messages, target: [room, :messages]
    def append(db, room, message)
      full = Message.load_one(db, message.id) or return
      r = Renderer.new(db)
      html = r.message_html(room, full)
      Cable.broadcast(Cable.room_messages_stream(room.type, room.id), r.turbo_stream_tag("append", "messages_#{room.dom_key}", html))
    end

    # The message partial as Message#broadcast_create renders it. In Rails this
    # render is what fills the fragment cache for a new message, so later page
    # renders reuse it verbatim (tokenless boost forms, example.org host).
    def fragment(db, room, full, host = Renderer::HOST, base_url = Renderer::BASE_URL)
      Renderer.new(db, host, base_url).message_html(room, full)
    end

    # boost.broadcast_append_to (partial messages/boosts/boost, cached).
    def boost_fragment(db, boost, host, base_url)
      r = Renderer.new(db, host, base_url)
      r.cached_boost(boost)
    end
  end
end
