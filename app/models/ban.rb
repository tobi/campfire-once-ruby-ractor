# frozen_string_literal: true

require "ipaddr"

module Campfire
  # Ban records (upstream Ban). `Ban.banned?` lives with the request filter.
  module Ban
    module_function

    # Ban#ip_address_is_public: create! raises on private/invalid addresses,
    # rolling back the whole ban as Rails does.
    def create!(db, user_id, ip, now = Clock.now_db)
      raise ArgumentError, "Ip address cannot be a private or internal IP address" unless public_ip?(ip)
      db.execute("INSERT INTO bans (user_id, ip_address, created_at, updated_at) VALUES (?, ?, ?, ?)".freeze, user_id, ip, now, now)
    end

    def public_ip?(ip)
      addr = IPAddr.new(ip)
      !(addr.loopback? || addr.private? || addr.link_local?)
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      false
    end
  end
end
