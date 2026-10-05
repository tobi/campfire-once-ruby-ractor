# frozen_string_literal: true

require "ipaddr"
require "socket"
require "uri"

module Campfire
  # Web Push subscriptions (upstream Push::Subscription). Delivery is the
  # job handlers' business; this is storage plus endpoint validation.
  class PushSubscription < Struct.new(:id, :user_id, :endpoint, :p256dh_key, :auth_key, :user_agent, :created_at, :updated_at)
    COLS = "id, user_id, endpoint, p256dh_key, auth_key, user_agent, created_at, updated_at"
    PERMITTED_ENDPOINT_HOSTS = %w[
      jmt17.google.com
      fcm.googleapis.com
      updates.push.services.mozilla.com
      web.push.apple.com
      notify.windows.com
    ].freeze
    BLOCKED = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
      192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 64:ff9b::/96 100::/64 2001:db8::/32 fc00::/7 fe80::/10 ff00::/8
    ].map { |c| IPAddr.new(c) }.freeze

    class << self
      # Current.user.push_subscriptions (insertion order, as has_many loads them).
      def for_user(db, user_id)
        db.query_array("SELECT #{COLS} FROM push_subscriptions WHERE user_id = ? ORDER BY id".freeze, user_id).map! { |r| new(*r) }
      end

      def find_for_user(db, user_id, id)
        row = db.query_single_array("SELECT #{COLS} FROM push_subscriptions WHERE user_id = ? AND id = ?".freeze, user_id, id.to_i)
        row && new(*row)
      end

      # @push_subscriptions.find_by(endpoint:, p256dh_key:, auth_key:)
      def find_by_keys(db, user_id, endpoint, p256dh, auth)
        row = db.query_single_array("SELECT #{COLS} FROM push_subscriptions WHERE user_id = ? AND endpoint IS ? AND p256dh_key IS ? AND auth_key IS ? ORDER BY id LIMIT 1".freeze,
          user_id, endpoint, p256dh, auth)
        row && new(*row)
      end

      def create!(db, user_id, endpoint, p256dh, auth, user_agent, now: Clock.now_db)
        db.execute("INSERT INTO push_subscriptions (user_id, endpoint, p256dh_key, auth_key, user_agent, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)".freeze,
          user_id, endpoint, p256dh, auth, user_agent, now, now)
        new(db.last_insert_rowid, user_id, endpoint, p256dh, auth, user_agent, now, now)
      end

      def destroy_for_user(db, user_id, id)
        db.execute("DELETE FROM push_subscriptions WHERE user_id = ? AND id = ?".freeze, user_id, id.to_i)
      end

      # validate :endpoint presence + validate_endpoint_url
      def valid_endpoint?(endpoint, resolver: method(:resolve_public_ip))
        return false if endpoint.nil? || endpoint.to_s.strip.empty?
        uri = (URI.parse(endpoint) rescue nil)
        return false if uri.nil? || uri.scheme != "https" || uri.port != 443
        host = uri.host&.downcase
        return false if host.nil? || host.empty?
        return false unless PERMITTED_ENDPOINT_HOSTS.any? { |p| host == p || host.end_with?(".#{p}") }
        !resolver.call(host).nil?
      end

      # PrivateNetworkGuard.resolve: first public address, or nil.
      def resolve_public_ip(host)
        # Resolv (the fiber scheduler's resolver) isn't Ractor-shareable, so
        # resolve with getaddrinfo on a plain Thread (as Outbound.resolve does).
        Thread.new { Addrinfo.getaddrinfo(host, 443, nil, :STREAM) }.value.each do |ai|
          ip = IPAddr.new(ai.ip_address) rescue next
          ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
          return ai.ip_address unless BLOCKED.any? { |b| b.family == ip.family && b.include?(ip) }
        end
        nil
      rescue SocketError
        nil
      end
    end

    def valid?(resolver: PushSubscription.method(:resolve_public_ip)) = PushSubscription.valid_endpoint?(endpoint, resolver: resolver)

    def touch!(db, now: Clock.now_db)
      db.execute("UPDATE push_subscriptions SET updated_at = ? WHERE id = ?".freeze, now, id)
      self.updated_at = now
    end
  end
end
