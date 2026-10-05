# frozen_string_literal: true

module Campfire
  module Cable
    # ActionCable::Channel::Base, reduced to what the app's channels use:
    # subscribed/unsubscribed hooks, stream_from/stream_for, reject, actions
    # performed by the client and on_subscribe/on_unsubscribe callbacks.
    class Channel
      CHANNELS = {} # client channel name => class; filled at boot, then frozen

      class << self
        def find(name) = name.is_a?(String) ? CHANNELS[name] : nil

        # Registers the class under the name the client subscribes with
        # ("RoomChannel"). Class-level state is set eagerly at load time (it is
        # frozen before worker Ractors read it), never memoized lazily.
        def channel(name)
          @channel_name = RailsCompat.underscore(name.split("::").last.delete_suffix("Channel")).freeze
          CHANNELS[name] = self
        end

        # Rails' channel_name: "TypingNotificationsChannel" -> "typing_notifications".
        def channel_name = @channel_name

        # Public methods the client may invoke with {"action": "..."}.
        def actions(*names) = @actions = (inherited_actions + names.map(&:to_s)).freeze
        def inherited_actions = @actions || (superclass.respond_to?(:inherited_actions) ? superclass.inherited_actions : EMPTY)
        def action?(name) = inherited_actions.include?(name)

        def on_subscribe(name) = @on_subscribe = [*subscribe_callbacks, name].freeze
        def on_unsubscribe(name) = @on_unsubscribe = [*unsubscribe_callbacks, name].freeze
        def subscribe_callbacks = @on_subscribe || (superclass.respond_to?(:subscribe_callbacks) ? superclass.subscribe_callbacks : EMPTY)
        def unsubscribe_callbacks = @on_unsubscribe || (superclass.respond_to?(:unsubscribe_callbacks) ? superclass.unsubscribe_callbacks : EMPTY)
      end
      EMPTY = [].freeze

      attr_reader :connection, :identifier, :identifier_json, :params, :streams

      def initialize(connection, identifier, identifier_json, params)
        @connection = connection
        @identifier = identifier
        @identifier_json = identifier_json
        @params = params
        @streams = nil
        @rejected = false
      end

      def current_user = @connection.user
      def db = DB.connection
      def subscription_rejected? = @rejected

      # True when confirmed.
      def subscribe_to_channel
        subscribed
        if @rejected
          stop_all_streams
          false
        else
          self.class.subscribe_callbacks.each { |cb| send(cb) }
          true
        end
      end

      def unsubscribe_from_channel
        unsubscribed
        self.class.unsubscribe_callbacks.each { |cb| send(cb) }
      ensure
        stop_all_streams
      end

      def perform_action(data)
        action = data["action"]
        action = "receive" unless action.is_a?(String)
        return unless self.class.action?(action)
        method(action).arity.zero? ? public_send(action) : public_send(action, data)
      end

      def subscribed; end
      def unsubscribed; end

      def reject = @rejected = true

      def stream_from(name)
        name = -name.to_s
        (@streams ||= []) << name
        Registry.current.stream_from(name, self)
      end

      def stream_for(room) = stream_from(broadcasting_for(room))

      def broadcasting_for(room) = Cable.room_stream(self.class.channel_name, room[1], room[0])

      def broadcast_to(room, payload) = Cable.broadcast(broadcasting_for(room), payload)

      def stop_all_streams
        return unless @streams
        registry = Registry.current
        @streams.each { |s| registry.stop_stream(s, self) }
        @streams = nil
      end

      # ActiveModel integer casting of params[:room_id].
      def self.cast_id(v)
        case v
        when Integer then v
        when Float then v.finite? ? v.to_i : nil
        when String then v.match?(/\A\s*[+-]?\d/) ? v.to_i : nil
        end
      end

      ROOM_FOR_USER = "SELECT rooms.id, rooms.type FROM rooms INNER JOIN memberships ON memberships.room_id = rooms.id " \
        "WHERE memberships.user_id = ? AND rooms.id = ? LIMIT 1"

      # current_user.rooms.find_by(id:): [id, type] or nil.
      def find_user_room(id)
        id = Channel.cast_id(id) or return nil
        db.query_single_array(ROOM_FOR_USER, current_user.id, id)
      end
    end
  end
end
