# frozen_string_literal: true

require "json"

module Campfire
  module Storage
    # Marcel 1.1.0 content type identification (magic bytes, declared type,
    # extension; the most specific wins), from the same tables the Go port
    # generated (storage/mime.json).
    module Mime
      data = JSON.parse(File.read(File.join(__dir__, "mime.json")))
      convert = ->(matches) do
        matches.map do |offset, range_end, hex, children|
          [offset, range_end, hex && [hex].pack("H*"), convert.(children)]
        end
      end
      EXTENSIONS = data["extensions"]
      TYPE_EXTENSIONS = data["type_extensions"]
      PARENTS = data["parents"]
      MAGIC = data["magic"].map { |type, matches| [type.downcase, convert.(matches)] }
      reach = ->(matches) do
        matches.map { |o, e, v, c| [(e >= 0 ? e : o) + (v ? v.bytesize : 0), reach.(c)].max }.max || 0
      end
      PREFIX_LENGTH = MAGIC.map { |_, m| reach.(m) }.max
      OCTET = "application/octet-stream"
      Ractor.make_shareable(EXTENSIONS)
      Ractor.make_shareable(TYPE_EXTENSIONS)
      Ractor.make_shareable(PARENTS)
      Ractor.make_shareable(MAGIC)

      module_function

      # Marcel::MimeType.for(extension:) ("jpg" / ".JPG" -> "image/jpeg"), or nil.
      def for_extension(ext)
        return nil if ext.nil? || ext.empty?
        ext = ext.delete_prefix(".")
        EXTENSIONS[ext] || EXTENSIONS[ext.downcase]
      end

      # Marcel::Magic.new(type).extensions.first
      def extension_for(type) = TYPE_EXTENSIONS[type]&.first

      def matches?(data, matches)
        size = data.bytesize
        matches.each do |offset, range_end, value, children|
          next unless value
          length = value.bytesize
          length += range_end - offset if range_end >= 0
          next if length > 0 && offset >= size
          window = length > 0 ? data.byteslice(offset, length) : ""
          hit = range_end >= 0 ? window.include?(value) : window == value
          return true if hit && (children.empty? || matches?(data, children))
        end
        false
      end

      def child?(child, parent)
        return true if child == parent
        (PARENTS[child] || EMPTY).any? { |p| child?(p, parent) }
      end
      EMPTY = [].freeze

      # Marcel::MimeType.for(io, name:, declared_type:). `data` needs only the
      # first PREFIX_LENGTH bytes.
      def identify(data, name, declared)
        data = data.b
        candidates = []
        MAGIC.each do |type, matches|
          if matches?(data, matches)
            candidates << type
            break
          end
        end
        if declared
          d = declared.downcase
          if (i = d.index(/[;, \t\n\r\v\f]/))
            d = d[0, i]
          end
          candidates << d if d != OCTET && d.include?("/")
        end
        if name
          ext = File.extname(name.to_s)
          ext = "" if File.basename(name.to_s).delete_suffix(ext).empty?
          if (t = for_extension(ext))
            candidates << t
          end
        end
        candidates << OCTET
        pick = candidates[0]
        candidates.each_with_index { |c, i| pick = c if i > 0 && child?(c, pick) }
        pick
      end
    end
  end
end
