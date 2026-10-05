# frozen_string_literal: true

require "ipaddr"
require "socket"

module Campfire
  # RestrictedHTTP::PrivateNetworkGuard over the surfguard gem's default policy
  # (Surfguard.resolve_public_ips / blocked_address?), as ref-rust's net/guard.rs
  # ports it: a host goes in, the first public address to pin comes out (nil when
  # it only resolves to blocked addresses, is malformed or doesn't resolve).
  #
  # Numeric hosts never reach DNS; names must be plain LDH labels. IPv4 answers
  # come before IPv6 ones, in resolver order within each family.
  module PrivateNetworkGuard
    # CIDR lists as frozen [first, last] integer pairs (IPAddr objects aren't
    # Ractor-shareable).
    range = ->(cidr) { r = IPAddr.new(cidr).to_range; [r.first.to_i, r.last.to_i].freeze }
    nets = ->(list) { list.split.map(&range).freeze }

    DISALLOWED_IPV4 = nets.("0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 168.63.129.16/32 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4")
    DISALLOWED_IPV6 = nets.("::/128 100::/64 100:0:0:1::/64 2001::/32 2001:2::/48 2001:db8::/32 2002::/16 3fff::/20 5f00::/16
      fec0::/10 ff00::/8")
    IANA_ALLOCATED_IPV6_UNICAST = nets.("2001::/23 2001:200::/23 2001:400::/23 2001:600::/23 2001:800::/22 2001:c00::/23
      2001:e00::/23 2001:1200::/23 2001:1400::/22 2001:1800::/23 2001:1a00::/23 2001:1c00::/22 2001:2000::/19 2001:4000::/23
      2001:4200::/23 2001:4400::/23 2001:4600::/23 2001:4800::/23 2001:4a00::/23 2001:4c00::/23 2001:5000::/20 2001:8000::/19
      2001:a000::/20 2001:b000::/20 2002::/16 2003::/18 2400::/12 2410::/12 2600::/12 2610::/23 2620::/23 2630::/12 2800::/12
      2a00::/12 2a10::/12 2c00::/12")
    GLOBALLY_REACHABLE = nets.("2001:3::/32 2001:4:112::/48")
    IETF_PROTOCOL_ASSIGNMENTS = range.("2001::/23")
    NAT64_WELL_KNOWN = range.("64:ff9b::/96")
    NAT64_LOCAL_USE = range.("64:ff9b:1::/48")
    IPV4_MAPPED = range.("::ffff:0:0/96")
    IPV4_TRANSLATABLE = range.("::ffff:0:0:0/96")
    IPV4_COMPATIBLE = range.("::/96")
    UNIQUE_LOCAL = range.("fc00::/7")
    LINK_LOCAL_V6 = range.("fe80::/10")

    LABEL = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/
    LEGACY_PART = /\A(?:0[xX][0-9a-fA-F]+|[0-9]*)\z/
    DOTTED_QUAD = /\A(?:(?:0|[1-9][0-9]*)\.){3}(?:0|[1-9][0-9]*)\z/
    MAX_HOST_BYTES = 255
    MAX_ADDRESSES = 256

    module_function

    # PrivateNetworkGuard.resolve(hostname): the first public address, or nil.
    def resolve(host) = resolve_public_ips(host)&.first

    # Surfguard.resolve_public_ips: the public addresses (an empty list for a host
    # that is malformed or only resolves to blocked addresses), or nil when the
    # lookup fails or comes back empty (Surfguard::Unresolvable).
    def resolve_public_ips(host)
      host = host.to_s
      return [] unless normal_host?(host)
      addresses = numeric_literals(host)
      return [] if addresses == :invalid
      addresses = safe_lookup(host) if addresses == :name
      return nil if addresses.nil? || addresses.empty? || addresses.size > MAX_ADDRESSES
      v4 = []
      v6 = []
      addresses.uniq.each do |ip|
        next if blocked_address?(ip)
        (ip.ipv4? ? v4 : v6) << ip.to_s
      end
      v4.concat(v6)
    end

    # DNS, with getaddrinfo on a plain Thread (Thread#value yields to the fiber
    # scheduler; Resolv's resolver isn't Ractor-shareable). -> [IPAddr]
    def lookup(host)
      Outbound.resolve(host, nil).map { |ip| IPAddr.new(ip) }
    end

    # A failed lookup is no addresses (Surfguard::Unresolvable); a deadline
    # around the caller still gets through.
    def safe_lookup(host)
      lookup(host)
    rescue Async::TimeoutError
      raise
    rescue StandardError
      nil
    end

    def normal_host?(host)
      host.ascii_only? && !host.empty? && host.bytesize <= MAX_HOST_BYTES && !host.include?("\0") && !host.include?("%")
    end

    # -> [IPAddr] for a numeric host, :name for one to look up, :invalid
    def numeric_literals(host)
      return :invalid if !valid_host_syntax?(host) || malformed_numeric_host_candidate?(host)
      if (ip = getaddrinfo_numeric(host) || ip_literal(host))
        return [ip]
      end
      numeric_host_candidate?(host) ? :invalid : :name
    end

    def valid_host_syntax?(host)
      return true if host.include?(":") || legacy_ipv4_shape?(host) || ip_literal(host)
      host.delete_suffix(".").split(".", -1).all? { |label| label.match?(LABEL) }
    end

    def numeric_host_candidate?(host) = host.include?(":") || legacy_ipv4_shape?(host)

    def malformed_numeric_host_candidate?(host)
      return false if host.include?(":")
      core = host.sub(%r{\A[%/]+}, "")
      core = core[/\A[^%\/]*/]
      malformed = core != host || core.split(".", -1).any?(&:empty?)
      malformed && legacy_ipv4_shape?(core) && !ip_literal(host)
    end

    # 1 to 4 dot-separated (empty parts ignored) decimal or 0x-hex numbers.
    def legacy_ipv4_shape?(text)
      parts = text.split(".").reject(&:empty?)
      parts.size.between?(1, 4) && parts.all? { |p| p.match?(LEGACY_PART) && p != "0x" && p != "0X" }
    end

    # IPAddr.new(text) for one full address: a dotted quad, or IPv6 with optional brackets.
    def ip_literal(text)
      if text.start_with?("[") && text.end_with?("]")
        ip = (IPAddr.new(text[1...-1]) rescue nil)
        return ip&.ipv6? && !text.include?("/") ? ip : nil
      end
      if text.include?(":")
        ip = (IPAddr.new(text) rescue nil)
        return ip&.ipv6? && !text.include?("/") ? ip : nil
      end
      text.match?(DOTTED_QUAD) ? (IPAddr.new(text) rescue nil) : nil
    end

    # glibc getaddrinfo(AI_NUMERICHOST): inet_aton forms for IPv4, inet_pton for IPv6.
    def getaddrinfo_numeric(host)
      ai = Addrinfo.getaddrinfo(host, nil, nil, :STREAM, nil, Socket::AI_NUMERICHOST).first or return nil
      IPAddr.new(ai.ip_address)
    rescue SocketError, IPAddr::Error
      nil
    end

    # Surfguard.blocked_address?
    def blocked_address?(ip)
      ip = IPAddr.new(ip.to_s) unless ip.is_a?(IPAddr)
      n = ip.to_i
      return disallowed_ipv4?(n) if ip.ipv4?
      return true if in?(IPV4_MAPPED, n) || in?(IPV4_COMPATIBLE, n) || in?(NAT64_LOCAL_USE, n)
      return disallowed_ipv4?(n & 0xffff_ffff) if in?(NAT64_WELL_KNOWN, n) || in?(IPV4_TRANSLATABLE, n)
      disallowed_ipv6?(n)
    end

    def in?(net, n) = n >= net[0] && n <= net[1]
    def disallowed_ipv4?(n) = DISALLOWED_IPV4.any? { |net| in?(net, n) }

    def disallowed_ipv6?(n)
      return false if GLOBALLY_REACHABLE.any? { |net| in?(net, n) }
      return true if in?(UNIQUE_LOCAL, n) || n == 1 || in?(LINK_LOCAL_V6, n) || in?(IETF_PROTOCOL_ASSIGNMENTS, n)
      return true if DISALLOWED_IPV6.any? { |net| in?(net, n) }
      IANA_ALLOCATED_IPV6_UNICAST.none? { |net| in?(net, n) }
    end
  end
end
