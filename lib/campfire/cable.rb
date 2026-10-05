# frozen_string_literal: true

require "async/websocket/response"
require "protocol/websocket/framer"
require_relative "cable/frames"
require_relative "cable/registry"
require_relative "cable/connection"
require_relative "cable/channel"

# Falcon wraps every response body for its request metrics, and the wrapper
# hides Hijack#stream?, which pushes WebSocket traffic through an extra body
# queue and task. Forward it, so a hijacked body gets the raw connection stream.
if defined?(Falcon::Body::RequestFinished)
  class Falcon::Body::RequestFinished
    def stream? = @body.stream?
    def call(stream) = @body.call(stream)
  end
end

module Campfire
  # Action Cable server (actioncable-v1-json) on async-websocket.
  #
  # Every worker Ractor holds its own registry of sockets and subscriptions
  # (Ractor-local, so no locks). Broadcasts go through the Bus, which hands each
  # one to every worker; the worker serializes the frame once and enqueues the
  # same frozen String on each local subscriber's bounded queue.
  #
  # Public API:
  #   Cable.broadcast(stream, payload)              # any Ractor; all workers
  #   Cable.disconnect_user(user_id, reconnect:)    # any Ractor; all workers
  #   Cable.local_broadcast(stream, payload)        # Bus -> this worker only
  #   Cable.local_disconnect(user_id, reconnect)    # Bus -> this worker only
  #
  # `payload` is the Action Cable `message`: a String (Turbo Stream HTML; sent
  # as a JSON string) or a Hash/Array (sent as a JSON object/array).
  module Cable
    PROTOCOLS = ["actioncable-v1-json", "actioncable-unsupported"].freeze
    NOT_FOUND = "Page not found"
    # CAMPFIRE_CABLE_DEBUG=1 names the worker Ractor in the upgrade response
    # (x-campfire-worker), so tests can prove cross-worker delivery.
    DEBUG_WORKER = ENV["CAMPFIRE_CABLE_DEBUG"] == "1"

    module_function

    # ---- publishing (any Ractor) ----------------------------------------

    # Encodes the message once in the caller, then fans out through the Bus.
    def broadcast(stream, payload)
      Bus.publish([:cable, stream.to_s, Frames.encode_message(payload)])
      nil
    end

    def disconnect_user(user_id, reconnect: false)
      Bus.publish([:disconnect, user_id.to_i, reconnect ? true : false])
      nil
    end

    # Stream names used by the channels (Rails' broadcasting names).
    def user_reads_stream(user_id) = "user_#{user_id}_reads"
    def user_unreads_stream(user_id) = "user_#{user_id}_unreads"

    # `stream_for room` in RoomChannel/PresenceChannel/TypingNotificationsChannel:
    # "<channel_name>:<room GID param>", e.g. "typing_notifications:Z2lk...".
    def room_stream(channel_name, room_type, room_id)
      "#{channel_name}:#{RailsCompat::GID.build(room_type, room_id).to_param}"
    end

    # `turbo_stream_from room, :messages` / `broadcast_*_to room, :messages`.
    def room_messages_stream(room_type, room_id)
      "#{RailsCompat::GID.build(room_type, room_id).to_param}:messages"
    end

    # ---- delivery (inside a worker, called by Bus) ------------------------

    def local_broadcast(stream, payload)
      Registry.current.broadcast(stream, Frames.encode_message(payload))
    end

    # `json` is an already-encoded message (see .broadcast).
    def local_broadcast_json(stream, json)
      Registry.current.broadcast(stream, json)
    end

    def local_disconnect(user_id, reconnect)
      Registry.current.disconnect_user(user_id, reconnect)
    end

    # Starts this worker's heartbeat (one ping frame per beat, shared by all sockets).
    def attach(task)
      Registry.current.start_beat(task)
    end

    # ---- the /cable endpoint ----------------------------------------------

    def call(request)
      return not_found unless websocket?(request) && allowed_origin?(request)

      user, token = authenticate(request)
      offered = request.headers["sec-websocket-protocol"]
      protocol = offered && (offered.to_s.split(",").map!(&:strip) & PROTOCOLS).first
      headers = DEBUG_WORKER ? [["x-campfire-worker", Ractor[:worker_index].to_s]] : nil
      Async::WebSocket::Response.for(request, headers, protocol: protocol) do |stream|
        if user
          Connection.new(stream, user, token).run
        else
          Connection.reject_unauthorized(stream)
        end
      end
    end

    def websocket?(request)
      Array(request.protocol).any? { |p| p.casecmp?("websocket") }
    end

    # Rails' allow_same_origin_as_host (allowed_request_origins is unset).
    def allowed_origin?(request)
      origin = request.headers["origin"]&.to_s or return false
      proto = request.headers["x-forwarded-proto"]&.to_s&.split(",")&.first&.strip
      proto = "http" if proto.nil? || proto.empty?
      host = request.authority || request.headers["host"]&.to_s
      origin == "#{proto}://#{host}"
    end

    # ApplicationCable::Connection#find_verified_user: the session_token cookie.
    def authenticate(request)
      raw = cookie(request, Controller::TOKEN_COOKIE) or return nil
      token = Cache.session_token(raw) or return nil
      db = DB.connection
      user_id = db.query_single_splat("SELECT user_id FROM sessions WHERE token = ? LIMIT 1".freeze, token) or return nil
      row = db.query_single_array("SELECT id, name FROM users WHERE id = ?".freeze, user_id) or return nil
      [CurrentUser.new(row[0], row[1]).freeze, token]
    end

    def cookie(request, name)
      header = request.headers["cookie"] or return nil
      header.to_s.split(/; */).each do |pair|
        k, v = pair.split("=", 2)
        return RailsCompat.unescape_cookie(v) if k == name && v
      end
      nil
    end

    def not_found
      Responses.build(404, [["content-type", "text/plain; charset=utf-8"]], NOT_FOUND)
    end

    CurrentUser = Struct.new(:id, :name)
  end
end
