# frozen_string_literal: true

require_relative "entities"

module Campfire
  module RichText
    class Error < StandardError; end

    # A pure-Ruby HTML5 fragment parser (tokenizer + tree construction), ported from
    # golang.org/x/net/html as patched for Gumbo/Nokogiri compatibility in ref-go:
    # source attribute order, legacy select modes, disabled scripting, and Gumbo's
    # 400-depth / 400-attribute limits. Only the fragment-parsing paths are kept.
    module HTML5
      class ParseError < Error; end

      ELEMENT = 1
      TEXT = 2
      COMMENT = 3
      DOCUMENT = 4
      MARKER = 5

      # Elements carry a flat attribute list: [key, value, namespace, key, value, namespace, ...].
      class Node
        attr_accessor :type, :data, :ns, :attrs, :parent, :children

        def initialize(type, data, attrs = nil, ns = nil)
          @type = type
          @data = data
          @attrs = attrs
          @ns = ns
          @parent = nil
          @children = type == TEXT || type == COMMENT ? nil : []
        end

        def element? = @type == ELEMENT
        def text? = @type == TEXT
        def html?(name) = @type == ELEMENT && @ns.nil? && @data == name

        def append(child)
          child.parent = self
          @children << child
          child
        end

        def insert_before(child, ref)
          return append(child) unless ref
          child.parent = self
          @children.insert(@children.index(ref), child)
          child
        end

        def remove(child)
          @children.delete_at(@children.index(child))
          child.parent = nil
          child
        end

        def detach
          @parent&.remove(self)
          self
        end

        def prev_sibling
          return unless @parent
          i = @parent.children.index(self)
          i > 0 ? @parent.children[i - 1] : nil
        end

        def last_child = @children&.last

        def shallow_clone
          Node.new(@type, @data, @attrs&.dup, @ns)
        end

        def deep_clone
          copy = Node.new(@type, @data, @attrs&.dup, @ns)
          @children&.each { |c| copy.append(c.deep_clone) }
          copy
        end

        def [](key)
          a = @attrs or return nil
          i = 0
          n = a.size
          while i < n
            return a[i + 1] if a[i] == key
            i += 3
          end
          nil
        end

        def []=(key, value)
          a = (@attrs ||= [])
          i = 0
          n = a.size
          while i < n
            if a[i] == key
              a[i + 1] = value
              return value
            end
            i += 3
          end
          a << key << value << nil
          value
        end

        def delete_attr(key)
          a = @attrs or return
          i = 0
          while i < a.size
            return a.slice!(i, 3) if a[i] == key
            i += 3
          end
        end
      end

      MARKER_NODE = Ractor.make_shareable(Node.new(MARKER, nil))

      def self.set(words) = Ractor.make_shareable(words.split.to_h { |w| [w, true] })

      SPECIAL = set("address applet area article aside base basefont bgsound blockquote body br button caption center col
        colgroup dd details dir div dl dt embed fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6
        head header hgroup hr html iframe img input keygen li link listing main marquee menu meta nav noembed noframes
        noscript object ol p param plaintext pre script section select source style summary table tbody td template
        textarea tfoot th thead title tr track ul wbr xmp")
      BREAKOUT = set("b big blockquote body br center code dd div dl dt em embed h1 h2 h3 h4 h5 h6 head hr i img li
        listing menu meta nobr ol p pre ruby s small span strong strike sub sup table tt u ul var")
      SVG_TAGS = Ractor.make_shareable(%w[altGlyph altGlyphDef altGlyphItem animateColor animateMotion animateTransform
        clipPath feBlend feColorMatrix feComponentTransfer feComposite feConvolveMatrix feDiffuseLighting
        feDisplacementMap feDistantLight feFlood feFuncA feFuncB feFuncG feFuncR feGaussianBlur feImage feMerge
        feMergeNode feMorphology feOffset fePointLight feSpecularLighting feSpotLight feTile feTurbulence foreignObject
        glyphRef linearGradient radialGradient textPath].to_h { |n| [n.downcase, n] })
      SVG_ATTRS = Ractor.make_shareable(%w[attributeName attributeType baseFrequency baseProfile calcMode clipPathUnits
        diffuseConstant edgeMode filterUnits glyphRef gradientTransform gradientUnits kernelMatrix kernelUnitLength
        keyPoints keySplines keyTimes lengthAdjust limitingConeAngle markerHeight markerUnits markerWidth
        maskContentUnits maskUnits numOctaves pathLength patternContentUnits patternTransform patternUnits pointsAtX
        pointsAtY pointsAtZ preserveAlpha preserveAspectRatio primitiveUnits refX refY repeatCount repeatDur
        requiredExtensions requiredFeatures specularConstant specularExponent spreadMethod startOffset stdDeviation
        stitchTiles surfaceScale systemLanguage tableValues targetX targetY textLength viewBox viewTarget
        xChannelSelector yChannelSelector zoomAndPan].to_h { |n| [n.downcase, n] })
      MATHML_ATTRS = Ractor.make_shareable({ "definitionurl" => "definitionURL" })
      FOREIGN_ATTRS = set("xlink:actuate xlink:arcrole xlink:href xlink:role xlink:show xlink:title xlink:type
        xml:lang xml:space xmlns:xlink")
      SCOPE_STOP = Ractor.make_shareable({
        nil => %w[applet caption html table td th marquee object template],
        "math" => %w[annotation-xml mi mn mo ms mtext],
        "svg" => %w[desc foreignObject title]
      })
      RAW_START = set("iframe noembed noframes noscript plaintext script style textarea title xmp")
      WIN1252 = Ractor.make_shareable([0x20AC, 0x81, 0x201A, 0x192, 0x201E, 0x2026, 0x2020, 0x2021, 0x2C6, 0x2030,
        0x160, 0x2039, 0x152, 0x8D, 0x17D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x2DC,
        0x2122, 0x161, 0x203A, 0x153, 0x9D, 0x17E, 0x178])

      # Token types.
      T_EOF = 0
      T_TEXT = 1
      T_START = 2
      T_END = 3
      T_SELF_CLOSING = 4
      T_COMMENT = 5
      T_DOCTYPE = 6

      REPLACEMENT = "�"
      NUL = "\0"
      UTF8 = Encoding::UTF_8

      module_function

      def utf8(s) = s.force_encoding(UTF8)

      def unescape(s, attribute)
        amp = s.byteindex("&") or return s
        b = s.b
        out = String.new(capacity: b.bytesize, encoding: Encoding::BINARY)
        out << b.byteslice(0, amp)
        src = amp
        len = b.bytesize
        while src < len
          nxt = b.byteindex("&", src)
          unless nxt
            out << b.byteslice(src, len - src)
            break
          end
          out << b.byteslice(src, nxt - src) if nxt > src
          src = nxt
          str, consumed = unescape_entity(b, src, attribute)
          if str
            out << str.b
            src += consumed
          else
            out << "&"
            src += 1
          end
        end
        utf8(out)
      end

      # Returns [replacement, bytes consumed] for the character reference at b[i], or nil.
      def unescape_entity(b, i, attribute)
        len = b.bytesize
        j = i + 1
        return nil if j >= len
        if b.getbyte(j) == 35 # '#'
          return nil if len - i <= 2
          j += 1
          c = b.getbyte(j)
          hex = c == 120 || c == 88
          j += 1 if hex
          j0 = j
          x = 0
          while j < len
            c = b.getbyte(j)
            if hex
              d = if c >= 48 && c <= 57 then c - 48
              elsif c >= 97 && c <= 102 then c - 87
              elsif c >= 65 && c <= 70 then c - 55
              end
              break unless d
              x = 16 * x + d if x <= 0x10FFFF
            else
              break unless c >= 48 && c <= 57
              x = 10 * x + c - 48 if x <= 0x10FFFF
            end
            j += 1
          end
          return nil if j == j0
          j += 1 if j < len && b.getbyte(j) == 59
          if x >= 0x80 && x <= 0x9F
            x = WIN1252[x - 0x80]
          elsif x == 0 || (x >= 0xD800 && x <= 0xDFFF) || x > 0x10FFFF
            x = 0xFFFD
          end
          return [[x].pack("U"), j - i]
        end
        while j < len
          c = b.getbyte(j)
          j += 1
          next if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57)
          j -= 1 if c != 59
          break
        end
        name = b.byteslice(i + 1, j - i - 1)
        return nil if name.empty?
        if attribute && !name.end_with?(";") && j < len && b.getbyte(j) == 61
          return nil
        end
        if (v = ENTITIES[name])
          return [v, j - i]
        end
        unless attribute
          k = [name.bytesize - 1, LONGEST_ENTITY_WITHOUT_SEMICOLON].min
          while k > 1
            if (v = ENTITIES[name.byteslice(0, k)])
              return [v, k + 1]
            end
            k -= 1
          end
        end
        nil
      end

      def convert_newlines(s)
        return s unless s.include?("\r")
        s.gsub(/\r\n?/, "\n")
      end

      class Tokenizer
        attr_accessor :allow_cdata
        attr_reader :tt

        def initialize(src, raw_tag = nil)
          @s = src.b
          @len = @s.bytesize
          @raw_start = 0
          @pos = 0 # raw.end
          @data_start = 0
          @data_end = 0
          @attr = []
          @attr_names = {}
          @pa_ks = @pa_ke = @pa_vs = @pa_ve = 0
          @raw_tag = raw_tag
          @eof = false
          @allow_cdata = false
          @text_is_raw = false
          @convert_nul = false
          @tt = T_EOF
        end

        def next_is_not_raw_text = @raw_tag = nil

        def next_token
          @raw_start = @pos
          @data_start = @pos
          @data_end = @pos
          return @tt = T_EOF if @eof
          if @raw_tag
            if @raw_tag == "plaintext"
              @pos = @len
              @eof = true
              @data_end = @pos
              @text_is_raw = true
            else
              read_raw_or_rcdata
            end
            if @data_end > @data_start
              @convert_nul = true
              return @tt = T_TEXT
            end
          end
          @text_is_raw = false
          @convert_nul = false
          s = @s
          loop do
            lt = s.byteindex("<", @pos)
            unless lt
              @pos = @len
              @eof = true
              break
            end
            @pos = lt + 1
            c = read_byte
            break if @eof
            type = if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) then T_START
            elsif c == 47 then T_END
            elsif c == 33 || c == 63 then T_COMMENT
            else
              @pos -= 1
              next
            end
            x = @pos - 2
            if @raw_start < x
              @pos = x
              @data_end = x
              return @tt = T_TEXT
            end
            case type
            when T_START
              return @tt = read_start_tag
            when T_END
              c = read_byte
              break if @eof
              return @tt = T_COMMENT if c == 62
              if (c >= 97 && c <= 122) || (c >= 65 && c <= 90)
                read_tag(false)
                return @tt = @eof ? T_EOF : T_END
              end
              @pos -= 1
              read_until_close_angle
              return @tt = T_COMMENT
            else
              return @tt = read_markup_declaration if c == 33
              @pos -= 1
              read_until_close_angle
              return @tt = T_COMMENT
            end
          end
          if @raw_start < @pos
            @data_end = @pos
            return @tt = T_TEXT
          end
          @tt = T_EOF
        end

        # Text of a text, comment or doctype token.
        def text
          s = HTML5.utf8(@s.byteslice(@data_start, @data_end - @data_start))
          s = HTML5.convert_newlines(s)
          s = s.gsub(NUL, REPLACEMENT) if (@convert_nul || @tt == T_COMMENT) && s.include?(NUL)
          s = HTML5.unescape(s, false) unless @text_is_raw
          s
        end

        def tag_name
          s = @s.byteslice(@data_start, @data_end - @data_start)
          s.downcase!(:ascii)
          s = HTML5.utf8(s)
          s.include?(NUL) ? s.gsub(NUL, REPLACEMENT) : s
        end

        # Flat [key, value, nil, ...] list, or nil when the tag has no attributes.
        def tag_attrs
          return nil if @attr.empty? || @tt == T_END
          out = Array.new(@attr.size / 4 * 3)
          i = 0
          o = 0
          a = @attr
          while i < a.size
            k = @s.byteslice(a[i], a[i + 1] - a[i])
            k.downcase!(:ascii)
            k = HTML5.utf8(k)
            k = k.gsub(NUL, REPLACEMENT) if k.include?(NUL)
            v = HTML5.utf8(@s.byteslice(a[i + 2], a[i + 3] - a[i + 2]))
            v = v.gsub(NUL, REPLACEMENT) if v.include?(NUL)
            out[o] = k
            out[o + 1] = HTML5.unescape(HTML5.convert_newlines(v), true)
            i += 4
            o += 3
          end
          out
        end

        private

        def read_byte
          if @pos >= @len
            @eof = true
            return 0
          end
          c = @s.getbyte(@pos)
          @pos += 1
          c
        end

        def skip_white_space
          return if @eof
          loop do
            c = read_byte
            return if @eof
            unless c == 32 || c == 10 || c == 13 || c == 9 || c == 12
              @pos -= 1
              return
            end
          end
        end

        def read_raw_or_rcdata
          if @raw_tag == "script"
            read_script
            @text_is_raw = true
            @raw_tag = nil
            return
          end
          loop do
            c = read_byte
            break if @eof
            next unless c == 60
            c = read_byte
            break if @eof
            if c != 47
              @pos -= 1
              next
            end
            break if read_raw_end_tag || @eof
          end
          @data_end = @pos
          @text_is_raw = @raw_tag != "textarea" && @raw_tag != "title"
          @raw_tag = nil
        end

        def read_raw_end_tag(tag = @raw_tag)
          i = 0
          while i < tag.bytesize
            c = read_byte
            return false if @eof
            t = tag.getbyte(i)
            if c != t && c != t - 32
              @pos -= 1
              return false
            end
            i += 1
          end
          c = read_byte
          return false if @eof
          if c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 47 || c == 62
            @pos -= 3 + tag.bytesize
            return true
          end
          @pos -= 1
          false
        end

        def read_script
          state = :data
          loop do
            case state
            when :data
              c = read_byte
              break if @eof
              state = :lt if c == 60
            when :lt
              c = read_byte
              break if @eof
              if c == 47
                break if read_raw_end_tag("script") || @eof
                state = :data
              elsif c == 33
                state = :escape_start
              else
                @pos -= 1
                state = :data
              end
            when :escape_start
              c = read_byte
              break if @eof
              if c == 45 then state = :escape_start_dash
              else
                @pos -= 1
                state = :data
              end
            when :escape_start_dash
              c = read_byte
              break if @eof
              if c == 45 then state = :escaped_dash_dash
              else
                @pos -= 1
                state = :data
              end
            when :escaped
              c = read_byte
              break if @eof
              state = :escaped_dash if c == 45
              state = :escaped_lt if c == 60
            when :escaped_dash
              c = read_byte
              break if @eof
              state = c == 45 ? :escaped_dash_dash : c == 60 ? :escaped_lt : :escaped
            when :escaped_dash_dash
              c = read_byte
              break if @eof
              state = case c
              when 45 then :escaped_dash_dash
              when 60 then :escaped_lt
              when 62 then :data
              else :escaped
              end
            when :escaped_lt
              c = read_byte
              break if @eof
              if c == 47
                break if read_raw_end_tag("script") || @eof
                state = :escaped
              elsif (c >= 97 && c <= 122) || (c >= 65 && c <= 90)
                @pos -= 1
                state = :double_escape_start
              else
                @pos -= 1
                state = :data
              end
            when :double_escape_start
              state = nil
              "script".each_byte do |t|
                c = read_byte
                break state = :eof if @eof
                if c != t && c != t - 32
                  @pos -= 1
                  break state = :escaped
                end
              end
              break if state == :eof
              unless state
                c = read_byte
                break if @eof
                if c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 47 || c == 62
                  state = :double_escaped
                else
                  @pos -= 1
                  state = :escaped
                end
              end
            when :double_escaped
              c = read_byte
              break if @eof
              state = :double_escaped_dash if c == 45
              state = :double_escaped_lt if c == 60
            when :double_escaped_dash
              c = read_byte
              break if @eof
              state = c == 45 ? :double_escaped_dash_dash : c == 60 ? :double_escaped_lt : :double_escaped
            when :double_escaped_dash_dash
              c = read_byte
              break if @eof
              state = case c
              when 45 then :double_escaped_dash_dash
              when 60 then :double_escaped_lt
              when 62 then :data
              else :double_escaped
              end
            when :double_escaped_lt
              c = read_byte
              break if @eof
              if c == 47
                if read_raw_end_tag("script")
                  @pos += 9
                  state = :escaped
                else
                  break if @eof
                  state = :double_escaped
                end
              else
                @pos -= 1
                state = :double_escaped
              end
            end
          end
          @data_end = @pos
        end

        def read_comment
          @data_start = @pos
          dash = 0
          beginning = true
          loop do
            c = read_byte
            if @eof
              @data_end = abrupt_comment_end
              break
            end
            case c
            when 45
              dash += 1
              next
            when 62
              if dash >= 2 || beginning
                @data_end = @pos - 3
                break
              end
            when 33
              if dash >= 2
                c = read_byte
                if @eof
                  @data_end = abrupt_comment_end
                  break
                elsif c == 62
                  @data_end = @pos - 4
                  break
                elsif c == 45
                  dash = 1
                  beginning = false
                  next
                end
              end
            end
            dash = 0
            beginning = false
          end
          @data_end = @data_start if @data_end < @data_start
        end

        def abrupt_comment_end
          raw = @s.byteslice(@raw_start, @pos - @raw_start)
          if raw.bytesize >= 4
            raw = raw.byteslice(4, raw.bytesize - 4)
            return @pos - 3 if raw.end_with?("--!")
            return @pos - 2 if raw.end_with?("--")
            return @pos - 1 if raw.end_with?("-")
          end
          @pos
        end

        def read_until_close_angle
          @data_start = @pos
          gt = @s.byteindex(">", @pos)
          if gt
            @pos = gt + 1
            @data_end = gt
          else
            @pos = @len
            @eof = true
            @data_end = @pos
          end
        end

        def read_markup_declaration
          @data_start = @pos
          c0 = read_byte
          if @eof
            @data_end = @pos
            return T_COMMENT
          end
          c1 = read_byte
          if @eof
            @data_end = @pos
            @data_end -= 1 if c0 == 62
            return T_COMMENT
          end
          if c0 == 45 && c1 == 45
            read_comment
            return T_COMMENT
          end
          @pos -= 2
          return T_DOCTYPE if read_doctype
          if @allow_cdata && read_cdata
            @convert_nul = true
            return T_TEXT
          end
          read_until_close_angle
          T_COMMENT
        end

        def read_prefix(word, case_insensitive)
          word.each_byte do |w|
            c = read_byte
            if @eof
              @pos = @data_start
              @eof = false
              return false
            end
            unless c == w || (case_insensitive && c == w + 32)
              @pos = @data_start
              return false
            end
          end
          true
        end

        def read_doctype
          return false unless read_prefix("DOCTYPE", true)
          skip_white_space
          if @eof
            @data_start = @data_end = @pos
            return true
          end
          read_until_close_angle
          true
        end

        def read_cdata
          return false unless read_prefix("[CDATA[", false)
          @data_start = @pos
          brackets = 0
          loop do
            c = read_byte
            if @eof
              @data_end = @pos
              return true
            end
            if c == 93
              brackets += 1
            elsif c == 62 && brackets >= 2
              @data_end = @pos - 3
              return true
            else
              brackets = 0
            end
          end
        end

        def read_start_tag
          read_tag(true)
          return T_EOF if @eof
          name = @s.byteslice(@data_start, @data_end - @data_start)
          name.downcase!(:ascii)
          @raw_tag = name if RAW_START[name]
          n = @attr.size
          if @s.getbyte(@pos - 2) == 47 && (n == 0 || @pos - 2 != @attr[n - 1] - 1)
            return T_SELF_CLOSING
          end
          T_START
        end

        def read_tag(save)
          @attr.clear
          @attr_names.clear
          read_tag_name
          count = 0
          skip_white_space
          return if @eof
          loop do
            c = read_byte
            break if @eof || c == 62
            @pos -= 1
            read_tag_attr_key
            if @pa_ks != @pa_ke
              count += 1
              raise ParseError, "Attributes per element limit exceeded" if count > 400
            end
            read_tag_attr_val
            if save && @pa_ks != @pa_ke
              key = @s.byteslice(@pa_ks, @pa_ke - @pa_ks)
              key.downcase!(:ascii)
              unless @attr_names[key]
                @attr << @pa_ks << @pa_ke << @pa_vs << @pa_ve
                @attr_names[key] = true
              end
            end
            skip_white_space
            break if @eof
          end
        end

        def read_tag_name
          @data_start = @pos - 1
          loop do
            c = read_byte
            if @eof
              @data_end = @pos
              return
            end
            if c == 32 || c == 10 || c == 13 || c == 9 || c == 12
              @data_end = @pos - 1
              return
            elsif c == 47 || c == 62
              @pos -= 1
              @data_end = @pos
              return
            end
          end
        end

        def read_tag_attr_key
          @pa_ks = @pos
          loop do
            c = read_byte
            if @eof
              @pa_ke = @pos
              return
            end
            next if c == 61 && @pa_ks + 1 == @pos
            if c == 61 || c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 47 || c == 62
              @pos -= 1
              @pa_ke = @pos
              return
            end
          end
        end

        def read_tag_attr_val
          @pa_vs = @pa_ve = @pos
          skip_white_space
          return if @eof
          c = read_byte
          return if @eof || c == 47
          if c != 61
            @pos -= 1
            return
          end
          skip_white_space
          return if @eof
          quote = read_byte
          return if @eof
          if quote == 62
            @pos -= 1
          elsif quote == 39 || quote == 34
            @pa_vs = @pos
            q = @s.byteindex(quote == 34 ? '"' : "'", @pos)
            if q
              @pos = q + 1
              @pa_ve = q
            else
              @pos = @len
              @eof = true
              @pa_ve = @pos
            end
          else
            @pa_vs = @pos - 1
            loop do
              c = read_byte
              if @eof
                @pa_ve = @pos
                return
              end
              if c == 32 || c == 10 || c == 13 || c == 9 || c == 12
                @pa_ve = @pos - 1
                return
              elsif c == 62
                @pos -= 1
                @pa_ve = @pos
                return
              end
            end
          end
        end
      end

      # Tree construction for fragments (https://html.spec.whatwg.org/#parsing-html-fragments).
      class Parser
        WHITESPACE = " \t\r\n\f"
        LEADING_WS = /\A[ \t\r\n\f]+/
        ALL_WS = /\A[ \t\r\n\f]*\z/
        IMPLIED_END = HTML5.set("dd dt li optgroup option p rb rp rt rtc")
        TABLE_CONTEXT = HTML5.set("table tbody tfoot thead tr")
        H_TAGS = %w[h1 h2 h3 h4 h5 h6].freeze
        BLOCK_START = HTML5.set("address article aside blockquote center details dialog dir div dl fieldset figcaption
          figure footer header hgroup main menu nav ol p search section summary ul")
        BLOCK_END = HTML5.set("address article aside blockquote button center details dialog dir div dl fieldset
          figcaption figure footer header hgroup listing main menu nav ol pre search section summary ul")
        FORMATTING = HTML5.set("b big code em font i s small strike strong tt u")
        FORMATTING_END = HTML5.set("a b big code em font i nobr s small strike strong tt u")
        HEAD_TAGS = HTML5.set("base basefont bgsound link meta noframes script style template title")
        VOID_FORMAT = HTML5.set("area br embed img input keygen wbr")
        BODY_IGNORED = HTML5.set("caption col colgroup frame head tbody td tfoot th thead tr")
        EOF_OK = HTML5.set("dd dt li optgroup option p rb rp rt rtc tbody td tfoot th thead tr body html")
        P = %w[p].freeze
        TBODY_GROUP = %w[tbody thead tfoot].freeze
        TD_TH = %w[td th].freeze

        def initialize(src, context)
          @context = context
          tag = context&.ns ? nil : context&.data
          raw = case tag
          when "title", "textarea" then tag
          when "style", "xmp", "iframe", "noembed", "noframes", "script", "noscript", "plaintext" then "plaintext"
          end
          @tz = Tokenizer.new(src, raw)
          @tz.next_is_not_raw_text if tag == "noscript" # scripting is disabled
          @doc = Node.new(DOCUMENT, nil)
          @root = Node.new(ELEMENT, "html")
          @doc.append(@root)
          @oe = [@root]
          @afe = []
          @template_stack = []
          @form = nil
          @head = nil
          @frameset_ok = false
          @foster = false
          @self_closing = false
          @original_im = nil
          @template_stack << :in_template if tag == "template"
          reset_insertion_mode
          n = context
          while n
            if n.html?("form")
              @form = n
              break
            end
            n = n.parent
          end
        end

        def parse
          loop do
            top = @oe.last
            @tz.allow_cdata = !top.nil? && !top.ns.nil?
            tt = @tz.next_token
            case tt
            when T_TEXT, T_COMMENT, T_DOCTYPE
              @data = @tz.text
              @attrs = nil
            when T_START, T_END, T_SELF_CLOSING
              @data = @tz.tag_name
              @attrs = @tz.tag_attrs
            else
              @data = nil
              @attrs = nil
            end
            @tt = tt
            t = top_node
            table_text = tt == T_TEXT && TABLE_CONTEXT[t.data]
            parse_current_token
            break if tt == T_EOF
            raise ParseError, "Document tree depth limit exceeded" if !table_text && @oe.size > 401
          end
          @root.children
        end

        private

        def top_node = @oe.last || @doc

        def name_is?(n, name) = n.data == name

        def parse_current_token
          if @tt == T_SELF_CLOSING
            @self_closing = true
            @tt = T_START
          end
          consumed = false
          consumed = in_foreign_content? ? parse_foreign_content : step(@im) until consumed
          @self_closing = false
        end

        def step(im)
          case im
          when :in_body then in_body
          when :in_table then in_table
          when :in_table_body then in_table_body
          when :in_row then in_row
          when :in_cell then in_cell
          when :text then text_im
          when :in_select then in_select
          when :in_select_in_table then in_select_in_table
          when :in_caption then in_caption
          when :in_column_group then in_column_group
          when :in_template then in_template
          when :in_head then in_head
          when :ignore then true
          else raise ParseError, "unsupported insertion mode #{im}"
          end
        end

        def parse_implied(tt, name)
          saved = [@tt, @data, @attrs, @self_closing]
          @tt = tt
          @data = name
          @attrs = nil
          @self_closing = false
          parse_current_token
          @tt, @data, @attrs, @self_closing = saved
        end

        def index_in_scope(scope, tags)
          i = @oe.size - 1
          while i >= 0
            n = @oe[i]
            name = n.data
            if n.ns.nil?
              return i if tags.include?(name)
              case scope
              when :list_item then return -1 if name == "ol" || name == "ul"
              when :button then return -1 if name == "button"
              when :table then return -1 if name == "html" || name == "table" || name == "template"
              when :select then return -1 unless name == "optgroup" || name == "option"
              end
            end
            if (scope == :default || scope == :list_item || scope == :button) && SCOPE_STOP[n.ns].include?(name)
              return -1
            end
            i -= 1
          end
          -1
        end

        def in_scope?(scope, tags) = index_in_scope(scope, tags) != -1

        def pop_until(scope, tags)
          i = index_in_scope(scope, tags)
          return false if i == -1
          @oe.slice!(i..)
          true
        end

        def clear_stack_to_context(scope)
          i = @oe.size - 1
          while i >= 0
            name = @oe[i].data
            stop = case scope
            when :table then name == "html" || name == "table" || name == "template"
            when :table_row then name == "html" || name == "tr" || name == "template"
            when :table_body then name == "html" || name == "tbody" || name == "tfoot" || name == "thead" || name == "template"
            end
            if stop
              @oe.slice!(i + 1..)
              return
            end
            i -= 1
          end
        end

        def generate_implied_end_tags(except = nil)
          i = @oe.size - 1
          while i >= 0
            n = @oe[i]
            break unless n.type == ELEMENT && IMPLIED_END[n.data] && n.data != except
            i -= 1
          end
          @oe.slice!(i + 1..)
        end

        def oe_contains?(name) = @oe.any? { |n| n.ns.nil? && n.data == name }

        def special?(n)
          case n.ns
          when nil then SPECIAL[n.data]
          when "math" then %w[mi mo mn ms mtext annotation-xml].include?(n.data)
          when "svg" then n.data == "foreignObject" || n.data == "desc" || n.data == "title"
          end
        end

        def add_child(n)
          if should_foster_parent?
            foster_parent(n)
          else
            top_node.append(n)
          end
          push_open(n) if n.type == ELEMENT
        end

        def push_open(n)
          @oe << n
          raise ParseError, "Document tree depth limit exceeded" if @oe.size > 512
        end

        def should_foster_parent? = @foster && TABLE_CONTEXT[top_node.data]

        def foster_parent(n)
          table = template = nil
          i = @oe.size - 1
          i -= 1 while i >= 0 && @oe[i].data != "table"
          table = @oe[i] if i >= 0
          j = @oe.size - 1
          j -= 1 while j >= 0 && @oe[j].data != "template"
          template = @oe[j] if j >= 0
          if template && (table.nil? || j > i)
            template.append(n)
            return
          end
          parent = table ? table.parent : @oe[0]
          parent ||= @oe[i - 1]
          prev = table ? table.prev_sibling : parent.last_child
          if prev && prev.type == TEXT && n.type == TEXT
            prev.data += n.data
            return
          end
          parent.insert_before(n, table)
        end

        def add_text(text)
          return if text.empty?
          if should_foster_parent?
            foster_parent(Node.new(TEXT, text))
            return
          end
          last = top_node.last_child
          if last && last.type == TEXT
            last.data = last.data + text
            return
          end
          add_child(Node.new(TEXT, text))
        end

        def add_element
          add_child(Node.new(ELEMENT, @data, @attrs))
        end

        def add_comment
          add_child(Node.new(COMMENT, @data))
        end

        def same_attrs?(a, b)
          a ||= []
          b ||= []
          return false unless a.size == b.size
          i = 0
          while i < a.size
            found = false
            j = 0
            while j < b.size
              if b[j] == a[i] && b[j + 1] == a[i + 1] && b[j + 2] == a[i + 2]
                found = true
                break
              end
              j += 3
            end
            return false unless found
            i += 3
          end
          true
        end

        def add_formatting_element
          name = @data
          attrs = @attrs
          add_element
          identical = 0
          i = @afe.size - 1
          while i >= 0
            n = @afe[i]
            break if n.type == MARKER
            if n.type == ELEMENT && n.ns.nil? && n.data == name && same_attrs?(n.attrs, attrs)
              identical += 1
              @afe.delete_at(i) if identical >= 3
            end
            i -= 1
          end
          @afe << top_node
        end

        def clear_active_formatting
          loop do
            n = @afe.pop
            return if @afe.empty? || n.type == MARKER
          end
        end

        def reconstruct_active_formatting
          n = @afe.last or return
          return if n.type == MARKER || @oe.rindex(n)
          i = @afe.size - 1
          while n.type != MARKER && !@oe.rindex(n)
            if i == 0
              i = -1
              break
            end
            i -= 1
            n = @afe[i]
          end
          loop do
            i += 1
            clone = @afe[i].shallow_clone
            add_child(clone)
            @afe[i] = clone
            break if i == @afe.size - 1
          end
        end

        def reset_insertion_mode
          i = @oe.size - 1
          while i >= 0
            n = @oe[i]
            last = i == 0
            n = @context if last && @context
            if n.ns
              return @im = :in_body if last
              i -= 1
              next
            end
            case n.data
            when "select"
              unless last
                k = @oe.rindex(n)
                while k > 0
                  k -= 1
                  case @oe[k].data
                  when "template" then return @im = :in_select
                  when "table" then return @im = :in_select_in_table
                  end
                end
              end
              @im = :in_select
            when "td", "th" then @im = :in_cell
            when "tr" then @im = :in_row
            when "tbody", "thead", "tfoot" then @im = :in_table_body
            when "caption" then @im = :in_caption
            when "colgroup" then @im = :in_column_group
            when "table" then @im = :in_table
            when "template" then @im = @template_stack.last
            when "head" then @im = :in_head
            when "body" then @im = :in_body
            else
              return @im = :in_body if last
              i -= 1
              next
            end
            return @im
          end
        end

        def in_head
          case @tt
          when T_START
            case @data
            when "base", "basefont", "bgsound", "link", "meta"
              add_element
              @oe.pop
              @self_closing = false
              return true
            when "script", "title", "noframes", "style"
              add_element
              @original_im = @im
              @im = :text
              return true
            when "head" then return true
            when "template"
              if @oe.any?(&:ns)
                @im = :ignore
                return true
              end
              add_element
              @afe << MARKER_NODE
              @frameset_ok = false
              @im = :in_template
              @template_stack << :in_template
              return true
            end
          when T_END
            if @data == "template"
              return true unless oe_contains?("template")
              generate_implied_end_tags
              i = @oe.size - 1
              while i >= 0
                n = @oe[i]
                if n.ns.nil? && n.data == "template"
                  @oe.slice!(i..)
                  break
                end
                i -= 1
              end
              clear_active_formatting
              @template_stack.pop
              reset_insertion_mode
            end
            return true
          when T_COMMENT
            add_comment
            return true
          when T_DOCTYPE
            return true
          end
          @oe.pop
          @im = :in_body
          false
        end

        def copy_attributes(dst)
          a = @attrs or return
          i = 0
          while i < a.size
            dst[a[i]] = a[i + 1] if dst[a[i]].nil?
            i += 3
          end
        end

        def in_body
          case @tt
          when T_TEXT
            d = @data
            n = @oe.last
            if (n.data == "pre" || n.data == "listing") && n.children.empty?
              d = d.byteslice(1..) if d.start_with?("\r")
              d = d.byteslice(1..) if d.start_with?("\n")
            end
            d = d.delete(NUL) if d.include?(NUL)
            return true if d.empty?
            reconstruct_active_formatting
            add_text(d)
            @frameset_ok = false if @frameset_ok && !d.match?(ALL_WS)
          when T_START
            name = @data
            case name
            when "html"
              return true if oe_contains?("template")
              copy_attributes(@oe[0])
            when "body"
              return true if oe_contains?("template")
              if @oe.size >= 2 && @oe[1].html?("body")
                @frameset_ok = false
                copy_attributes(@oe[1])
              end
            when "frameset"
              return true # no <body> on the stack of a fragment parse
            when "h1", "h2", "h3", "h4", "h5", "h6"
              pop_until(:button, P)
              @oe.pop if H_TAGS.include?(top_node.data)
              add_element
            when "pre", "listing"
              pop_until(:button, P)
              add_element
              @frameset_ok = false
            when "form"
              return true if @form && !oe_contains?("template")
              pop_until(:button, P)
              add_element
              @form = top_node unless oe_contains?("template")
            when "li", "dd", "dt"
              @frameset_ok = false
              i = @oe.size - 1
              while i >= 0
                node = @oe[i]
                if name == "li" ? node.data == "li" : (node.data == "dd" || node.data == "dt")
                  @oe.slice!(i..)
                  break
                end
                break if special?(node) && !%w[address div p].include?(node.data)
                i -= 1
              end
              pop_until(:button, P)
              add_element
            when "plaintext"
              pop_until(:button, P)
              add_element
            when "button"
              pop_until(:default, %w[button])
              reconstruct_active_formatting
              add_element
              @frameset_ok = false
            when "a"
              i = @afe.size - 1
              while i >= 0 && @afe[i].type != MARKER
                n = @afe[i]
                if n.type == ELEMENT && n.data == "a"
                  adoption_agency("a")
                  @oe.delete(n)
                  @afe.delete(n)
                  break
                end
                i -= 1
              end
              reconstruct_active_formatting
              add_formatting_element
            when "nobr"
              reconstruct_active_formatting
              if in_scope?(:default, %w[nobr])
                adoption_agency("nobr")
                reconstruct_active_formatting
              end
              add_formatting_element
            when "applet", "marquee", "object"
              reconstruct_active_formatting
              add_element
              @afe << MARKER_NODE
              @frameset_ok = false
            when "table"
              pop_until(:button, P) # fragments are never in quirks mode
              add_element
              @frameset_ok = false
              @im = :in_table
              return true
            when "param", "source", "track"
              add_element
              @oe.pop
              @self_closing = false
            when "hr"
              pop_until(:button, P)
              add_element
              @oe.pop
              @self_closing = false
              @frameset_ok = false
            when "image"
              @data = "img"
              return false
            when "textarea"
              add_element
              @original_im = @im
              @frameset_ok = false
              @im = :text
            when "xmp"
              pop_until(:button, P)
              reconstruct_active_formatting
              @frameset_ok = false
              add_element
              @original_im = @im
              @im = :text
            when "iframe"
              @frameset_ok = false
              add_element
              @original_im = @im
              @im = :text
            when "noembed"
              add_element
              @original_im = @im
              @im = :text
            when "noscript"
              reconstruct_active_formatting
              add_element
              @tz.next_is_not_raw_text
            when "select"
              reconstruct_active_formatting
              add_element
              @frameset_ok = false
              @im = :in_select
              return true
            when "optgroup", "option"
              @oe.pop if top_node.data == "option"
              reconstruct_active_formatting
              add_element
            when "rb", "rtc"
              generate_implied_end_tags if in_scope?(:default, %w[ruby])
              add_element
            when "rp", "rt"
              generate_implied_end_tags("rtc") if in_scope?(:default, %w[ruby])
              add_element
            when "math", "svg"
              reconstruct_active_formatting
              adjust_attribute_names(name == "math" ? MATHML_ATTRS : SVG_ATTRS)
              adjust_foreign_attributes
              add_element
              top_node.ns = name
              if @self_closing
                @oe.pop
                @self_closing = false
              end
              return true
            else
              if HEAD_TAGS[name]
                return in_head
              elsif BLOCK_START[name]
                pop_until(:button, P)
                add_element
              elsif FORMATTING[name]
                reconstruct_active_formatting
                add_formatting_element
              elsif VOID_FORMAT[name]
                reconstruct_active_formatting
                add_element
                @oe.pop
                @self_closing = false
                if name == "input"
                  a = @attrs
                  i = 0
                  while a && i < a.size
                    return true if a[i] == "type" && a[i + 1].casecmp?("hidden")
                    i += 3
                  end
                end
                @frameset_ok = false
              elsif BODY_IGNORED[name]
                # Ignore the token.
              else
                reconstruct_active_formatting
                add_element
              end
            end
          when T_END
            name = @data
            case name
            when "body"
              # A fragment never has <body> in scope.
            when "html"
              return true
            when "form"
              if oe_contains?("template")
                i = index_in_scope(:default, %w[form])
                return true if i == -1
                generate_implied_end_tags
                return true unless @oe[i].data == "form"
                pop_until(:default, %w[form])
              else
                node = @form
                @form = nil
                i = index_in_scope(:default, %w[form])
                return true if node.nil? || i == -1 || !@oe[i].equal?(node)
                generate_implied_end_tags
                @oe.delete(node)
              end
            when "p"
              parse_implied(T_START, "p") unless in_scope?(:button, P)
              pop_until(:button, P)
            when "li"
              pop_until(:list_item, %w[li])
            when "dd", "dt"
              pop_until(:default, [name])
            when "h1", "h2", "h3", "h4", "h5", "h6"
              pop_until(:default, H_TAGS)
            when "applet", "marquee", "object"
              clear_active_formatting if pop_until(:default, [name])
            when "br"
              @tt = T_START
              return false
            when "template"
              return in_head
            else
              if BLOCK_END[name]
                pop_until(:default, [name])
              elsif FORMATTING_END[name]
                adoption_agency(name)
              else
                end_tag_other(name)
              end
            end
          when T_COMMENT
            add_comment
          when T_EOF
            unless @template_stack.empty?
              @im = :in_template
              return false
            end
          end
          true
        end

        def adoption_agency(tag)
          current = @oe.last
          if current.data == tag && !@afe.rindex(current)
            @oe.pop
            return
          end
          8.times do
            fe = nil
            j = @afe.size - 1
            while j >= 0
              break if @afe[j].type == MARKER
              if @afe[j].data == tag
                fe = @afe[j]
                break
              end
              j -= 1
            end
            return end_tag_other(tag) unless fe
            fe_index = @oe.rindex(fe)
            unless fe_index
              @afe.delete(fe)
              return
            end
            return unless in_scope?(:default, [tag])
            furthest = nil
            k = fe_index
            while k < @oe.size
              if special?(@oe[k])
                furthest = @oe[k]
                break
              end
              k += 1
            end
            unless furthest
              e = @oe.pop
              e = @oe.pop until e.equal?(fe)
              @afe.delete(e)
              return
            end
            common = @oe[fe_index - 1]
            bookmark = @afe.rindex(fe)
            last_node = furthest
            node = furthest
            x = @oe.rindex(node)
            j = 0
            loop do
              j += 1
              x -= 1
              node = @oe[x]
              break if node.equal?(fe)
              ni = @afe.rindex(node)
              if j > 3 && ni
                @afe.delete_at(ni)
                bookmark -= 1 if ni <= bookmark
                next
              end
              unless @afe.rindex(node)
                @oe.delete_at(@oe.rindex(node))
                next
              end
              clone = node.shallow_clone
              @afe[@afe.rindex(node)] = clone
              @oe[@oe.rindex(node)] = clone
              node = clone
              bookmark = @afe.rindex(node) + 1 if last_node.equal?(furthest)
              last_node.detach
              node.append(last_node)
              last_node = node
            end
            last_node.detach
            if TABLE_CONTEXT[common.data]
              foster_parent(last_node)
            else
              common.append(last_node)
            end
            clone = fe.shallow_clone
            furthest.children.each { |c| c.parent = clone }
            clone.children.concat(furthest.children)
            furthest.children.clear
            furthest.append(clone)
            old = @afe.rindex(fe)
            bookmark -= 1 if old && old < bookmark
            @afe.delete_at(old) if old
            @afe.insert(bookmark, clone)
            @oe.delete_at(@oe.rindex(fe))
            @oe.insert(@oe.rindex(furthest) + 1, clone)
          end
        end

        def end_tag_other(tag)
          i = @oe.size - 1
          while i >= 0
            n = @oe[i]
            if n.ns.nil? && n.data == tag
              @oe.slice!(i..)
              break
            end
            break if special?(n)
            i -= 1
          end
        end

        def text_im
          case @tt
          when T_EOF
            @oe.pop
          when T_TEXT
            d = @data
            n = @oe.last
            if n.data == "textarea" && n.children.empty?
              d = d.byteslice(1..) if d.start_with?("\r")
              d = d.byteslice(1..) if d.start_with?("\n")
            end
            add_text(d) unless d.empty?
            return true
          when T_END
            @oe.pop
          end
          @im = @original_im
          @original_im = nil
          @tt == T_END
        end

        def in_table
          case @tt
          when T_TEXT
            @data = @data.delete(NUL) if @data.include?(NUL)
            if TABLE_CONTEXT[@oe.last.data] && @data.match?(ALL_WS)
              add_text(@data)
              return true
            end
          when T_START
            case @data
            when "caption"
              clear_stack_to_context(:table)
              @afe << MARKER_NODE
              add_element
              @im = :in_caption
              return true
            when "colgroup"
              clear_stack_to_context(:table)
              add_element
              @im = :in_column_group
              return true
            when "col"
              parse_implied(T_START, "colgroup")
              return false
            when "tbody", "tfoot", "thead"
              clear_stack_to_context(:table)
              add_element
              @im = :in_table_body
              return true
            when "td", "th", "tr"
              parse_implied(T_START, "tbody")
              return false
            when "table"
              if pop_until(:table, %w[table])
                reset_insertion_mode
                return false
              end
              return true
            when "style", "script", "template"
              return in_head
            when "input"
              a = @attrs
              i = 0
              while a && i < a.size
                if a[i] == "type" && a[i + 1].casecmp?("hidden")
                  add_element
                  @oe.pop
                  return true
                end
                i += 3
              end
            when "form"
              return true if oe_contains?("template") || @form
              add_element
              @form = @oe.pop
            when "select"
              reconstruct_active_formatting
              @foster = true if TABLE_CONTEXT[top_node.data]
              add_element
              @foster = false
              @frameset_ok = false
              @im = :in_select_in_table
              return true
            end
          when T_END
            case @data
            when "table"
              reset_insertion_mode if pop_until(:table, %w[table])
              return true
            when "body", "caption", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr"
              return true
            when "template"
              return in_head
            end
          when T_COMMENT
            add_comment
            return true
          when T_DOCTYPE
            return true
          when T_EOF
            return in_body
          end
          @foster = true
          begin
            in_body
          ensure
            @foster = false
          end
        end

        def in_caption
          case @tt
          when T_START
            if %w[caption col colgroup tbody td tfoot thead tr].include?(@data)
              return true unless pop_until(:table, %w[caption])
              clear_active_formatting
              @im = :in_table
              return false
            end
          when T_END
            case @data
            when "caption"
              if pop_until(:table, %w[caption])
                clear_active_formatting
                @im = :in_table
              end
              return true
            when "table"
              return true unless pop_until(:table, %w[caption])
              clear_active_formatting
              @im = :in_table
              return false
            when "body", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr"
              return true
            end
          end
          in_body
        end

        def in_column_group
          case @tt
          when T_TEXT
            if (m = @data[LEADING_WS])
              add_text(m)
              return true if m.bytesize == @data.bytesize
              @data = @data.byteslice(m.bytesize..)
            end
          when T_COMMENT
            add_comment
            return true
          when T_DOCTYPE
            return true
          when T_START
            case @data
            when "html" then return in_body
            when "col"
              add_element
              @oe.pop
              @self_closing = false
              return true
            when "template" then return in_head
            end
          when T_END
            case @data
            when "colgroup"
              if @oe.last.data == "colgroup"
                @oe.pop
                @im = :in_table
              end
              return true
            when "col" then return true
            when "template" then return in_head
            end
          when T_EOF
            return in_body
          end
          return true unless @oe.last.data == "colgroup"
          @oe.pop
          @im = :in_table
          false
        end

        def in_table_body
          case @tt
          when T_START
            case @data
            when "tr"
              clear_stack_to_context(:table_body)
              add_element
              @im = :in_row
              return true
            when "td", "th"
              parse_implied(T_START, "tr")
              return false
            when "caption", "col", "colgroup", "tbody", "tfoot", "thead"
              if pop_until(:table, TBODY_GROUP)
                @im = :in_table
                return false
              end
              return true
            end
          when T_END
            case @data
            when "tbody", "tfoot", "thead"
              if in_scope?(:table, [@data])
                clear_stack_to_context(:table_body)
                @oe.pop
                @im = :in_table
              end
              return true
            when "table"
              if pop_until(:table, TBODY_GROUP)
                @im = :in_table
                return false
              end
              return true
            when "body", "caption", "col", "colgroup", "html", "td", "th", "tr"
              return true
            end
          when T_COMMENT
            add_comment
            return true
          end
          in_table
        end

        def in_row
          case @tt
          when T_START
            case @data
            when "td", "th"
              clear_stack_to_context(:table_row)
              add_element
              @afe << MARKER_NODE
              @im = :in_cell
              return true
            when "caption", "col", "colgroup", "tbody", "tfoot", "thead", "tr"
              if pop_until(:table, %w[tr])
                @im = :in_table_body
                return false
              end
              return true
            end
          when T_END
            case @data
            when "tr"
              @im = :in_table_body if pop_until(:table, %w[tr])
              return true
            when "table"
              if pop_until(:table, %w[tr])
                @im = :in_table_body
                return false
              end
              return true
            when "tbody", "tfoot", "thead"
              if in_scope?(:table, [@data])
                parse_implied(T_END, "tr")
                return false
              end
              return true
            when "body", "caption", "col", "colgroup", "html", "td", "th"
              return true
            end
          end
          in_table
        end

        def in_cell
          case @tt
          when T_START
            case @data
            when "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"
              if pop_until(:table, TD_TH)
                clear_active_formatting
                @im = :in_row
                return false
              end
              return true
            when "select"
              reconstruct_active_formatting
              add_element
              @frameset_ok = false
              @im = :in_select_in_table
              return true
            end
          when T_END
            case @data
            when "td", "th"
              return true unless pop_until(:table, [@data])
              clear_active_formatting
              @im = :in_row
              return true
            when "body", "caption", "col", "colgroup", "html"
              return true
            when "table", "tbody", "tfoot", "thead", "tr"
              return true unless in_scope?(:table, [@data])
              clear_active_formatting if pop_until(:table, TD_TH)
              @im = :in_row
              return false
            end
          end
          in_body
        end

        def in_select
          case @tt
          when T_TEXT
            add_text(@data.include?(NUL) ? @data.delete(NUL) : @data)
          when T_START
            case @data
            when "html" then return in_body
            when "option"
              @oe.pop if top_node.data == "option"
              add_element
            when "optgroup"
              @oe.pop if top_node.data == "option"
              @oe.pop if top_node.data == "optgroup"
              add_element
            when "hr"
              @oe.pop if top_node.data == "option"
              @oe.pop if top_node.data == "optgroup"
              add_element
              @oe.pop
              @self_closing = false
            when "select"
              return true unless pop_until(:select, %w[select])
              reset_insertion_mode
            when "input", "keygen", "textarea"
              if in_scope?(:select, %w[select])
                parse_implied(T_END, "select")
                return false
              end
              @tz.next_is_not_raw_text
              return true
            when "script", "template"
              return in_head
            when "iframe", "noembed", "noframes", "noscript", "plaintext", "style", "title", "xmp"
              @tz.next_is_not_raw_text
              return true
            end
          when T_END
            case @data
            when "option"
              @oe.pop if top_node.data == "option"
            when "optgroup"
              i = @oe.size - 1
              i -= 1 if @oe[i].data == "option"
              @oe.slice!(i..) if @oe[i].data == "optgroup"
            when "select"
              return true unless pop_until(:select, %w[select])
              reset_insertion_mode
            when "template"
              return in_head
            end
          when T_COMMENT
            add_comment
          when T_DOCTYPE
            return true
          when T_EOF
            return in_body
          end
          true
        end

        def in_select_in_table
          if (@tt == T_START || @tt == T_END) && %w[caption table tbody tfoot thead tr td th].include?(@data)
            return true if @tt == T_END && !in_scope?(:table, [@data])
            i = @oe.size - 1
            while i >= 0
              if @oe[i].data == "select"
                @oe.slice!(i..)
                break
              end
              i -= 1
            end
            reset_insertion_mode
            return false
          end
          in_select
        end

        def in_template
          case @tt
          when T_TEXT, T_COMMENT, T_DOCTYPE
            return in_body
          when T_START
            mode = case @data
            when "base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "template", "title"
              return in_head
            when "caption", "colgroup", "tbody", "tfoot", "thead" then :in_table
            when "col" then :in_column_group
            when "tr" then :in_table_body
            when "td", "th" then :in_row
            else :in_body
            end
            @template_stack.pop
            @template_stack << mode
            @im = mode
            return false
          when T_END
            return @data == "template" ? in_head : true
          when T_EOF
            return true unless oe_contains?("template")
            generate_implied_end_tags
            i = @oe.size - 1
            while i >= 0
              n = @oe[i]
              if n.ns.nil? && n.data == "template"
                @oe.slice!(i..)
                break
              end
              i -= 1
            end
            clear_active_formatting
            @template_stack.pop
            reset_insertion_mode
            return false
          end
          false
        end

        def adjust_attribute_names(map)
          a = @attrs or return
          i = 0
          while i < a.size
            if (n = map[a[i]])
              a[i] = n
            end
            i += 3
          end
        end

        def adjust_foreign_attributes
          a = @attrs or return
          i = 0
          while i < a.size
            k = a[i]
            if k.start_with?("x") && FOREIGN_ATTRS[k]
              ns, local = k.split(":", 2)
              a[i] = local
              a[i + 2] = ns
            end
            i += 3
          end
        end

        def html_integration_point?(n)
          return false unless n.type == ELEMENT
          case n.ns
          when "math"
            if n.data == "annotation-xml"
              a = n.attrs
              i = 0
              while a && i < a.size
                if a[i] == "encoding" && (a[i + 1].casecmp?("text/html") || a[i + 1].casecmp?("application/xhtml+xml"))
                  return true
                end
                i += 3
              end
            end
          when "svg"
            return n.data == "desc" || n.data == "foreignObject" || n.data == "title"
          end
          false
        end

        def mathml_text_integration_point?(n)
          n.ns == "math" && %w[mi mo mn ms mtext].include?(n.data)
        end

        def adjusted_current_node
          @oe.size == 1 && @context ? @context : @oe.last
        end

        def in_foreign_content?
          return false if @oe.empty?
          n = adjusted_current_node
          return false if n.ns.nil?
          if mathml_text_integration_point?(n)
            return false if @tt == T_START && @data != "mglyph" && @data != "malignmark"
            return false if @tt == T_TEXT
          end
          return false if n.ns == "math" && n.data == "annotation-xml" && @tt == T_START && @data == "svg"
          return false if html_integration_point?(n) && (@tt == T_START || @tt == T_TEXT)
          @tt != T_EOF
        end

        def parse_foreign_content
          case @tt
          when T_TEXT
            @frameset_ok = @data.match?(/\A[ \t\r\n\f\0]*\z/) if @frameset_ok
            @data = @data.gsub(NUL, REPLACEMENT) if @data.include?(NUL)
            add_text(@data)
          when T_COMMENT
            add_comment
          when T_START
            b = BREAKOUT[@data]
            if !b && @data == "font"
              a = @attrs
              i = 0
              while a && i < a.size
                if a[i] == "color" || a[i] == "face" || a[i] == "size"
                  b = true
                  break
                end
                i += 3
              end
            end
            if b
              i = @oe.size - 1
              while i >= 0
                n = @oe[i]
                if n.ns.nil? || html_integration_point?(n) || mathml_text_integration_point?(n)
                  @oe.slice!(i + 1..)
                  break
                end
                i -= 1
              end
              return step(@im)
            end
            current = adjusted_current_node
            case current.ns
            when "math"
              adjust_attribute_names(MATHML_ATTRS)
            when "svg"
              if (x = SVG_TAGS[@data])
                @data = x
              end
              adjust_attribute_names(SVG_ATTRS)
            end
            adjust_foreign_attributes
            ns = current.ns
            add_element
            top_node.ns = ns
            @tz.next_is_not_raw_text if ns
            if @self_closing
              @oe.pop
              @self_closing = false
            end
          when T_END
            if @oe.last.data.casecmp?(@data)
              @oe.pop
              return true
            end
            i = @oe.size - 1
            while i >= 0
              if @oe[i].data.casecmp?(@data)
                @oe.slice!(i..)
                return true
              end
              break if i > 0 && @oe[i - 1].ns.nil?
              i -= 1
            end
            return step(@im)
          end
          true
        end
      end

      # Parses +src+ as the inner HTML of an element named +context+ (nil means <body>).
      def parse_fragment(src, context = nil)
        src = src.byteslice(3..) if src.start_with?("﻿")
        ctx = context && context.type == ELEMENT ? Node.new(ELEMENT, context.data, nil, context.ns) : Node.new(ELEMENT, "body")
        ctx.parent = nil
        nodes = Parser.new(src, ctx).parse
        root = Node.new(DOCUMENT, nil)
        nodes.each { |n| n.parent = root }
        root.children = nodes
        root
      end
    end
  end
end
