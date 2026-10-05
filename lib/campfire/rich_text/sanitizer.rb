# frozen_string_literal: true

require_relative "dom"

module Campfire
  module RichText
    # Rails::HTML5::SafeListSanitizer as configured by Action Text and Campfire.
    # Modes: :default (bare sanitize helper), :filter (ContentFilters), :action
    # (Action Text render) and :auto (auto_link sanitize_options).
    module Sanitizer
      include HTML5
      set = HTML5.method(:set)

      DEFAULT_TAGS = set.("a abbr acronym address b big blockquote br cite code dd del dfn div dl dt em h1 h2 h3 h4 h5 h6
        hr i img ins kbd li mark ol p pre samp small span strong sub sup time tt ul var s u table thead tbody tfoot tr th td")
      ACTION_TAGS = set.("action-text-attachment figure figcaption video audio source embed")
      FILTER_TAGS = set.("action-text-attachment figure figcaption")
      DEFAULT_ATTRS = set.("abbr alt cite class datetime height href lang src title width xml:lang data-language")
      RICH_ATTRS = set.("sgid content-type url href filename filesize width height previewable presentation caption
        content controls poster data-language style value start")
      URI_ATTRS = set.("action cite href longdesc poster preload src xlink:href xml:base")
      NORMALIZED_ATTRS = set.("href action src")
      PROTOCOLS = set.("afs aim callto data ed2k fax ftp gopher http https irc line mailto modem news nntp rsync rtsp
        sftp sms ssh tag tel telnet urn webcal xmpp")
      DATA_TYPES = set.("image/gif image/jpeg image/png text/css text/plain")
      SCHEME = /\A([a-z][a-z0-9+.-]*)(?::|%3a|&#0*58|&#x0*3a|&#37;3a)/
      COLOR = %r{\A(?:[a-z]+|\#[0-9a-f]{3,8}|var\([\t\n\f\r ]*--[a-z0-9_-]+[\t\n\f\r ]*\)|(?:rgb|rgba|hsl|hsla)\([0-9a-z.,%\t\n\f\r /+-]*\))\z}i
      URI_JUNK = /[`\x00-\x20\x7F\u0080-\u0101]/
      CONTROLS = /[\x00-\x08\x0B\x0C\x0E-\x1F]/
      SPACE = /\A[[:space:]]+|[[:space:]]+\z/
      BLANK = /\A[[:space:]]*\z/
      URI_SPECIAL = /[ "]/
      URI_ESCAPES = Ractor.make_shareable({ " " => "%20", '"' => "%22" })
      PLAIN_UNSAFE = /[&<>\0\r\u00A0]/
      STYLE_KEYS = set.("color background-color")

      module_function

      def allowed_uri?(value)
        s = HTML5.unescape(value.gsub(URI_JUNK, ""), false).gsub(URI_JUNK, "").downcase
        s = s.gsub("&tab;", "").gsub("&newline;", "").gsub("&colon;", ":") if s.include?("&")
        m = SCHEME.match(s) or return true
        return false unless PROTOCOLS[m[1]]
        return true unless m[1] == "data"
        metadata, comma, = s.delete_prefix("data:").partition(",")
        return false if comma.empty?
        media = metadata.split(";", 2).first.to_s
        media = "text/plain" unless media.include?("/")
        DATA_TYPES.key?(media)
      end

      def sanitize(root, mode)
        DOM.walk(root) do |n|
          next if n.type == TEXT || n.parent.nil?
          tag = n.data
          allowed = if n.type != ELEMENT then false
          elsif mode == :filter then tag != "img" && (DEFAULT_TAGS[tag] || FILTER_TAGS[tag])
          else DEFAULT_TAGS[tag] || (mode == :action && ACTION_TAGS[tag])
          end
          unless allowed
            parent = n.parent
            if n.type == ELEMENT && n.ns.nil? && !n.children.empty?
              kids = parent.children
              n.children.each { |c| c.parent = parent }
              kids[kids.index(n), 0] = n.children
              n.children = []
            end
            parent.remove(n)
            next
          end
          scrub_attributes(n, mode) if n.attrs
        end
        root
      end

      def scrub_attributes(n, mode)
        a = n.attrs
        i = 0
        while i < a.size
          key = a[i + 2] ? "#{a[i + 2]}:#{a[i]}" : a[i]
          keep = DEFAULT_ATTRS[key] || (mode != :auto && RICH_ATTRS[key])
          if !keep || (URI_ATTRS[key] && !allowed_uri?(a[i + 1]))
            a.slice!(i, 3)
            next
          end
          if key == "src" && a[i + 1].match?(BLANK)
            a.slice!(i, 3)
          else
            i += 3
          end
          normalize_uris(a)
        end
        scrub_style(a)
        n.attrs = nil if a.empty?
      end

      def normalize_uris(a)
        j = 0
        while j < a.size
          if NORMALIZED_ATTRS[a[j]]
            v = a[j + 1]
            v = v.gsub(CONTROLS, "") if v.match?(CONTROLS)
            v = v.gsub(URI_SPECIAL, URI_ESCAPES) if v.match?(URI_SPECIAL)
            a[j + 1] = v
          end
          j += 3
        end
      end

      def scrub_style(a)
        i = 0
        i += 3 while i < a.size && a[i] != "style"
        return if i >= a.size
        safe = +""
        all = true
        a[i + 1].split(";").each do |declaration|
          next if declaration.match?(BLANK)
          key, _, value = declaration.partition(":")
          key = key.gsub(SPACE, "").downcase
          value = value.gsub(SPACE, "")
          if STYLE_KEYS[key] && value.match?(COLOR)
            safe << key << ": " << value << ";"
          else
            all = false
          end
        end
        if safe.empty?
          a.slice!(i, 3)
        elsif !all
          a[i + 1] = safe
        end
      end

      # Parse, sanitize and serialize a string (the view-level sanitize helper).
      def sanitize_string(s)
        return s unless s.match?(PLAIN_UNSAFE) # a lone text node serializes back unchanged
        DOM.serialize(sanitize(DOM.parse(s), :default))
      end
    end
  end
end
