# frozen_string_literal: true

require "digest/sha1"

module Campfire
  module Storage
    # ActiveStorage::Variation without the class: a variation is a Hash with
    # Symbol keys, in Rails' insertion order. Values keep Rails' types, which
    # matter for the digest: in-app named variants carry Symbols (`format:
    # :webp`), variations decoded from a URL key carry Strings ("webp").
    #
    #   key    = ActiveStorage.verifier.generate(transformations, purpose: :variation)
    #   digest = SHA1.base64digest(Marshal.dump(transformations))
    module Variation
      FORMATS = %w[png webp jpeg jpg gif tiff avif heic heif].freeze
      PURPOSE = "variation"
      EMPTY = {}.freeze

      module_function

      # Variation#default_to(format: f) == transformations.reverse_merge(format: f):
      # `format` moves first, keeping its own value when present.
      def default_to(variation, format)
        return variation if variation.first&.first == :format
        out = { format: variation.fetch(:format, format) }
        variation.each { |k, v| out[k] = v unless k == :format }
        out
      end

      def dump(variation) = Marshal.dump(variation)

      def digest(variation) = digest_dumped(dump(variation))

      def digest_dumped(dumped) = [Digest::SHA1.digest(dumped)].pack("m0")

      # Only ever loads strings we dumped ourselves (job arguments).
      def load(dumped) = Marshal.load(dumped)

      def encode(variation)
        Storage.verifier.generate(variation, purpose: PURPOSE)
      end

      # Variation.decode(key): the verified transformations with symbolized
      # keys (deep_symbolize_keys), or nil.
      def decode(key)
        value = Storage.verifier.verified(key, purpose: PURPOSE)
        value.is_a?(Hash) ? symbolize(value) : nil
      end

      def symbolize(value)
        case value
        when Hash then value.each_with_object({}) { |(k, v), h| h[k.to_sym] = symbolize(v) }
        when Array then value.map { |v| symbolize(v) }
        else value
        end
      end

      # Variation#format (transformations.fetch(:format, :png)) as a String,
      # or nil when not a supported image format.
      def format(variation)
        f = variation.fetch(:format, :png)
        f = f.to_s if f.is_a?(Symbol)
        f.is_a?(String) && FORMATS.include?(f.downcase) ? f : nil
      end

      # resize_to_limit [w, h] (either may be nil) or nil when absent.
      # Raises ArgumentError for anything we cannot process.
      def resize_to_limit(variation)
        dims = nil
        variation.each do |k, v|
          next if k == :format || v.nil? || v == false
          raise ArgumentError, "unsupported transformation #{k}" unless k == :resize_to_limit
          raise ArgumentError, "invalid resize dimensions" unless v.is_a?(Array) && v.size == 2
          v.each { |n| raise ArgumentError, "invalid resize dimension" unless n.nil? || (n.is_a?(Integer) && n > 0 && n <= 2_147_483_647) }
          raise ArgumentError, "missing resize dimensions" if v[0].nil? && v[1].nil?
          dims = v
        end
        dims
      end
    end
  end
end
