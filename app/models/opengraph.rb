# frozen_string_literal: true

require "strscan"
require "uri"
require "zlib"

module Campfire
  # Opengraph::Metadata / Location / Fetch / Document (app/models/opengraph): the
  # composer's link unfurling, as ref-rust's integrations/opengraph ports it.
  #
  # Every address is resolved through PrivateNetworkGuard and pinned, every
  # redirect is re-checked, documents are capped at 5MB and 10 responses. Requests
  # go through Outbound (async-http, so they yield to the Ractor's reactor) with
  # Net::HTTP's default headers, content decoding and response predicates.
  module Opengraph
    ATTRIBUTES = %w[title url image description].freeze
    BLANK = /\A[[:space:]]*\z/

    module_function

    # Object#blank?
    def blank?(value)
      case value
      when nil, false then true
      when String then value.match?(BLANK)
      when Hash, Array then value.empty?
      else false
      end
    end

    # A `rescue => e` in the Rails code swallows fetch failures; the unfurl's own
    # deadline has to get through.
    def swallow?(error) = !error.is_a?(Async::TimeoutError)

    def warn(message) = Log.info("WARN #{message}")

    # The slice of Nokogiri::HTML(html) (libxml2's legacy HTML parser) that
    # Opengraph::Document reads: every <meta> element's attributes. See ref-rust's
    # opengraph/html.rs: <script>/<style> hold raw text, comments and <!...>/<?...>
    # are skipped, names are lowercased, the first of a repeated attribute wins,
    # attribute values decode HTML 4 entities only with their ";" and numeric
    # references with or without one (an invalid one cuts the value short).
    module Document
      # libxml2's html40EntitiesTable (plus apos)
      ENTITIES = Ractor.make_shareable("AElig 198|Aacute 193|Acirc 194|Agrave 192|Alpha 913|Aring 197|Atilde 195|Auml 196|Beta 914|Ccedil 199|Chi 935|Dagger 8225|Delta 916|ETH 208|Eacute 201|Ecirc 202|Egrave 200|Epsilon 917|Eta 919|Euml 203|Gamma 915|Iacute 205|Icirc 206|Igrave 204|Iota 921|Iuml 207|Kappa 922|Lambda 923|Mu 924|Ntilde 209|Nu 925|OElig 338|Oacute 211|Ocirc 212|Ograve 210|Omega 937|Omicron 927|Oslash 216|Otilde 213|Ouml 214|Phi 934|Pi 928|Prime 8243|Psi 936|Rho 929|Scaron 352|Sigma 931|THORN 222|Tau 932|Theta 920|Uacute 218|Ucirc 219|Ugrave 217|Upsilon 933|Uuml 220|Xi 926|Yacute 221|Yuml 376|Zeta 918|aacute 225|acirc 226|acute 180|aelig 230|agrave 224|alefsym 8501|alpha 945|amp 38|and 8743|ang 8736|apos 39|aring 229|asymp 8776|atilde 227|auml 228|bdquo 8222|beta 946|brvbar 166|bull 8226|cap 8745|ccedil 231|cedil 184|cent 162|chi 967|circ 710|clubs 9827|cong 8773|copy 169|crarr 8629|cup 8746|curren 164|dArr 8659|dagger 8224|darr 8595|deg 176|delta 948|diams 9830|divide 247|eacute 233|ecirc 234|egrave 232|empty 8709|emsp 8195|ensp 8194|epsilon 949|equiv 8801|eta 951|eth 240|euml 235|euro 8364|exist 8707|fnof 402|forall 8704|frac12 189|frac14 188|frac34 190|frasl 8260|gamma 947|ge 8805|gt 62|hArr 8660|harr 8596|hearts 9829|hellip 8230|iacute 237|icirc 238|iexcl 161|igrave 236|image 8465|infin 8734|int 8747|iota 953|iquest 191|isin 8712|iuml 239|kappa 954|lArr 8656|lambda 955|lang 9001|laquo 171|larr 8592|lceil 8968|ldquo 8220|le 8804|lfloor 8970|lowast 8727|loz 9674|lrm 8206|lsaquo 8249|lsquo 8216|lt 60|macr 175|mdash 8212|micro 181|middot 183|minus 8722|mu 956|nabla 8711|nbsp 160|ndash 8211|ne 8800|ni 8715|not 172|notin 8713|nsub 8836|ntilde 241|nu 957|oacute 243|ocirc 244|oelig 339|ograve 242|oline 8254|omega 969|omicron 959|oplus 8853|or 8744|ordf 170|ordm 186|oslash 248|otilde 245|otimes 8855|ouml 246|para 182|part 8706|permil 8240|perp 8869|phi 966|pi 960|piv 982|plusmn 177|pound 163|prime 8242|prod 8719|prop 8733|psi 968|quot 34|rArr 8658|radic 8730|rang 9002|raquo 187|rarr 8594|rceil 8969|rdquo 8221|real 8476|reg 174|rfloor 8971|rho 961|rlm 8207|rsaquo 8250|rsquo 8217|sbquo 8218|scaron 353|sdot 8901|sect 167|shy 173|sigma 963|sigmaf 962|sim 8764|spades 9824|sub 8834|sube 8838|sum 8721|sup 8835|sup1 185|sup2 178|sup3 179|supe 8839|szlig 223|tau 964|there4 8756|theta 952|thetasym 977|thinsp 8201|thorn 254|tilde 732|times 215|trade 8482|uArr 8657|uacute 250|uarr 8593|ucirc 251|ugrave 249|uml 168|upsih 978|upsilon 965|uuml 252|weierp 8472|xi 958|yacute 253|yen 165|yuml 255|zeta 950|zwj 8205|zwnj 8204".split("|").to_h { |e| n, c = e.split(" "); [n, c.to_i.chr(Encoding::UTF_8)] })
      MAX_ATTRIBUTES = 256

      TEXT = /[^<]+/
      END_TAG = %r{</}
      COMMENT = /<!--/
      COMMENT_SHORT = /-?>/
      COMMENT_END = /--!?>/
      BOGUS_MARKUP = /<[!?]/
      START_TAG = /<(?=[A-Za-z])/
      GT = />/
      NAME = /[A-Za-z_:.][A-Za-z0-9:_.-]*/
      BLANKS = /[ \t\n\r]+/
      TAG_END = %r{/?>}
      SELF_CLOSE = %r{/>}
      EQ = /=/
      QUOTE = /["']/
      DQ = /"/
      SQ = /'/
      BOGUS_ATTRIBUTE = %r{(?:[^ \t\n\r>/]|/(?!>))+}
      DQ_TEXT = /[^"&]+/
      SQ_TEXT = /[^'&]+/
      UNQUOTED_TEXT = /[^&> \t\n\r]+/
      AMP = /&/
      CHAR_REF = /&#/
      HEX_REF = /&#[xX]/
      HEX_DIGITS = /\h+/
      DEC_DIGITS = /\d+/
      SEMI = /;/
      ENTITY_NAME = /[A-Za-z_:][A-Za-z0-9_:.-]*/
      LEADING_ZEROS = /\A0+/
      RAW_END = { "script" => %r{(?=</script)}i, "style" => %r{(?=</style)}i }.freeze
      CHARSET = /charset[ \t\n\v\f\r]*=[ \t\n\v\f\r]*([A-Za-z0-9_-]+)/i
      NON_ASCII = /[^\x00-\x7F]+/

      module_function

      # opengraph_attributes: from each meta whose property or name starts with
      # "og:", the key is that attribute (property when present) with every "og:"
      # removed, the value its non-blank content; later tags win. Without a meta
      # charset non-ASCII characters are dropped. -> {"title"=>..} in ATTRIBUTES order
      def opengraph_attributes(body)
        return {} if body.nil? || body.empty?
        metas = meta_elements(decode(body))
        keep_non_ascii = !meta_encoding(metas).nil?
        found = nil
        metas.each do |m|
          property = m["property"]
          name = m["name"]
          next unless property&.start_with?("og:") || name&.start_with?("og:")
          key = (property || name).gsub("og:", "")
          next unless ATTRIBUTES.include?(key)
          content = m["content"]
          next if content.nil? || content.match?(BLANK)
          content = content.gsub(NON_ASCII, "") unless keep_non_ascii || content.ascii_only?
          (found ||= {})[key] = content
        end
        return {} unless found
        ATTRIBUTES.each_with_object({}) { |k, h| h[k] = found[k] if found.key?(k) }
      end

      # libxml2 reading the body as UTF-8: valid sequences decode, any other byte
      # is taken as Latin-1. A NUL ends its input.
      def decode(body)
        s = body.dup.force_encoding(Encoding::UTF_8)
        s = s.scrub { |bad| bad.unpack("C*").pack("U*") } unless s.valid_encoding?
        (nul = s.byteindex("\0")) ? s.byteslice(0, nul) : s
      end

      # The <meta> elements' attributes, in document order. -> [Hash]
      def meta_elements(html)
        ss = StringScanner.new(html)
        metas = []
        until ss.eos?
          ss.skip(TEXT)
          break if ss.eos?
          if ss.skip(END_TAG)
            (ss.skip_until(GT) || ss.terminate) if ss.skip(NAME)
          elsif ss.skip(COMMENT)
            ss.skip(COMMENT_SHORT) || ss.skip_until(COMMENT_END) || ss.terminate
          elsif ss.skip(BOGUS_MARKUP)
            ss.skip_until(GT) || ss.terminate
          elsif ss.skip(START_TAG)
            name = ss.scan(NAME).downcase
            meta = name == "meta"
            attributes, self_closing = start_tag(ss, meta)
            if meta
              metas << attributes
            elsif !self_closing && (raw = RAW_END[name])
              ss.skip_until(raw) || ss.terminate
            end
          else
            ss.pos += 1 # a lone "<"
          end
        end
        metas
      end

      # htmlParseStartTag, after the name: -> [attributes (nil unless kept), self_closing]
      def start_tag(ss, keep)
        attributes = keep ? {} : nil
        ss.skip(BLANKS)
        until ss.eos? || ss.match?(TAG_END)
          if (attribute = ss.scan(NAME))
            ss.skip(BLANKS)
            value = ""
            if ss.skip(EQ)
              ss.skip(BLANKS)
              value = attribute_value(ss, keep)
            end
            if keep
              attribute.downcase!
              attributes[attribute] = value if attributes.size < MAX_ATTRIBUTES && !attributes.key?(attribute)
            end
          else
            ss.skip(BOGUS_ATTRIBUTE) || (ss.pos += 1) # dump the bogus attribute string
          end
          ss.skip(BLANKS)
        end
        self_closing = !ss.skip(SELF_CLOSE).nil?
        ss.skip(GT) unless self_closing
        [attributes, self_closing]
      end

      # htmlParseAttValue (references never span a stop character, so skipped
      # values of other tags needn't be decoded)
      def attribute_value(ss, decode)
        if (quote = ss.scan(QUOTE))
          dq = quote == '"'
          value = decode ? attribute_text(ss, dq ? DQ_TEXT : SQ_TEXT) : ss.skip_until(dq ? /(?=")/ : /(?=')/) || ss.terminate
          ss.skip(dq ? DQ : SQ)
          value
        else
          decode ? attribute_text(ss, UNQUOTED_TEXT) : ss.skip(%r{[^> \t\n\r]*})
        end
      end

      # htmlParseHTMLAttribute
      def attribute_text(ss, text)
        out = ss.scan(text) || +""
        return out unless ss.match?(AMP)
        out = +out if out.frozen?
        truncated = false
        while ss.match?(AMP)
          decoded = ss.match?(CHAR_REF) ? char_ref(ss) : entity_ref(ss)
          if decoded.nil?
            truncated = true
          elsif !truncated
            out << decoded
          end
          chunk = ss.scan(text)
          out << chunk if chunk && !truncated
        end
        out
      end

      # htmlParseCharRef: nil for a value that isn't an XML Char.
      def char_ref(ss)
        if ss.skip(HEX_REF)
          digits = ss.scan(HEX_DIGITS)
          radix = 16
        else
          ss.skip(CHAR_REF)
          digits = ss.scan(DEC_DIGITS)
          radix = 10
        end
        ss.skip(SEMI)
        digits = digits ? digits.sub(LEADING_ZEROS, "") : ""
        return nil if digits.length > 7 # past U+10FFFF whatever the radix
        v = digits.empty? ? 0 : digits.to_i(radix)
        if v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || (v >= 0x10000 && v <= 0x10FFFF)
          v.chr(Encoding::UTF_8)
        end
      end

      # htmlParseEntityRef: a known name followed by ";" decodes, else it stays.
      def entity_ref(ss)
        ss.skip(AMP)
        name = ss.scan(ENTITY_NAME)
        if name && ss.match?(SEMI) && (char = ENTITIES[name])
          ss.skip(SEMI)
          return char
        end
        name ? "&#{name}" : "&"
      end

      # Nokogiri::HTML4::Document#meta_encoding: the first meta[@charset], else the
      # charset of the first http-equiv="Content-Type" meta with a content.
      def meta_encoding(metas)
        if (meta = metas.find { |m| m.key?("charset") })
          return meta["charset"]
        end
        meta = metas.find { |m| m.key?("content") && m["http-equiv"]&.casecmp?("content-type") } or return nil
        meta["content"][CHARSET, 1]
      end
    end

    # Opengraph::Fetch: GET or HEAD against a pinned address, following up to 10
    # responses (any 3xx), each redirect target parsed, required to be http(s) and
    # resolved through the guard again. A document must be a 200 text/html of at
    # most 5MB, by Content-Length and by what is read.
    module Fetch
      ALLOWED_DOCUMENT_CONTENT_TYPE = "text/html"
      MAX_BODY_SIZE = 5 * 1024 * 1024
      MAX_REDIRECTS = 10
      # Each connect and read (Rails leaves Net::HTTP's 60s; the unfurl has 10s in all).
      TIMEOUT = 5
      # Net::HTTPGenericRequest's defaults (Host is the URL's authority).
      HEADERS = [["accept-encoding", "gzip;q=1.0,deflate;q=0.6,identity;q=0.3"], ["accept", "*/*"], ["user-agent", "Ruby"]].freeze
      DECODED = %w[gzip x-gzip deflate].freeze
      DIGITS = /\d+/

      class TooManyRedirectsError < StandardError; end
      class RedirectDeniedError < StandardError; end
      class Violation < StandardError; end

      module_function

      # -> the body (binary), or nil when the response isn't acceptable
      def fetch_document(url, ip)
        request(url, "GET", ip) { |response| body_if_acceptable(response) }
      end

      # -> the final response's Content-Type, whatever its status
      def fetch_content_type(url, ip)
        request(url, "HEAD", ip) { |response| header(response, "content-type") }
      end

      def request(url, verb, ip)
        MAX_REDIRECTS.times do
          location = nil
          Outbound.request(verb, url, HEADERS, ip: ip, timeout: TIMEOUT, authority: url.authority) do |response|
            return yield(response) unless response.status >= 300 && response.status < 400 # Net::HTTPRedirection
            location = header(response, "location")
          end
          url, ip = resolve_redirect(location)
        end
        raise TooManyRedirectsError
      end

      def resolve_redirect(location)
        url = URI.parse(location)
        raise RedirectDeniedError unless url.is_a?(URI::HTTP)
        ip = PrivateNetworkGuard.resolve(url.host) or raise Violation, "Attempt to access private IP via #{url.host}"
        [url, ip]
      end

      def header(response, name) = response.headers[name]&.to_s

      def body_if_acceptable(response)
        size_restricted_body(response) if response.status == 200 && content_type(response) == ALLOWED_DOCUMENT_CONTENT_TYPE &&
          content_length(response).to_i <= MAX_BODY_SIZE
      end

      # Net::HTTPHeader#content_type: "main/sub" as sent, parameters dropped.
      def content_type(response)
        value = header(response, "content-type") or return nil
        main, sub = value.split(";").first.to_s.split("/")
        main = main.to_s.strip
        sub ? "#{main}/#{sub.strip}" : main
      end

      # Net::HTTPHeader#content_length
      def content_length(response)
        value = header(response, "content-length") || response.body&.length&.to_s or return nil
        (value[DIGITS] or raise ArgumentError, "wrong Content-Length format").to_i
      end

      # Read in chunks, inflated as Net::HTTP does for the encodings it asked for,
      # giving up as soon as it runs past the limit.
      def size_restricted_body(response)
        body = response.body or return "".b
        encoding = header(response, "content-encoding")&.downcase
        inflate = Zlib::Inflate.new(32 + Zlib::MAX_WBITS) if DECODED.include?(encoding) && !header(response, "content-range")
        out = String.new(encoding: Encoding::BINARY)
        while (chunk = body.read)
          if inflate
            inflate.inflate(chunk) { |piece| return nil if out.bytesize + piece.bytesize > MAX_BODY_SIZE; out << piece }
          else
            return nil if out.bytesize + chunk.bytesize > MAX_BODY_SIZE
            out << chunk
          end
        end
        if inflate && inflate.total_in > 0
          rest = inflate.finish
          return nil if out.bytesize + rest.bytesize > MAX_BODY_SIZE
          out << rest
        end
        out
      ensure
        inflate&.close
      end
    end

    # Opengraph::Location: valid when it parses as http(s) and its host resolves
    # to a public address, which is memoized and pinned for the fetch.
    class Location
      FILES_AND_MEDIA_URL_REGEX = %r{\bhttps?://\S+\.(?:zip|tar|tar\.gz|tar\.bz2|tar\.xz|gz|bz2|rar|7z|dmg|exe|msi|pkg|deb|iso|jpg|jpeg|png|gif|bmp|mp4|mov|avi|mkv|wmv|flv|heic|heif|mp3|wav|ogg|aac|wma|webm|ogv|mpg|mpeg)\b}

      attr_reader :url

      def initialize(url)
        @url = url
      end

      # Both validations run, so the host is resolved even for a non-http URL.
      def valid?
        http = parsed_url.is_a?(URI::HTTP)
        public = !resolved_ip.nil?
        http && public
      end

      def read_html
        fetch_html if valid? && !url.match?(FILES_AND_MEDIA_URL_REGEX)
      end

      def fetch_content_type
        Fetch.fetch_content_type(parsed_url, resolved_ip) if valid?
      rescue StandardError => e
        raise unless Opengraph.swallow?(e)
        Opengraph.warn("Failed to fetch #{parsed_url} at #{resolved_ip} (#{e})")
        nil
      end

      def resolved_ip
        return @resolved_ip if defined?(@resolved_ip)
        @resolved_ip = parsed_url && PrivateNetworkGuard.resolve(parsed_url.host)
      end

      def parsed_url
        return @parsed_url if defined?(@parsed_url)
        @parsed_url = begin
          URI.parse(url)
        rescue StandardError
          nil
        end
      end

      private

      def fetch_html
        Fetch.fetch_document(parsed_url, resolved_ip)
      rescue StandardError => e
        raise unless Opengraph.swallow?(e)
        Opengraph.warn("Failed to fetch #{parsed_url} at #{resolved_ip} (#{e})")
        nil
      end
    end

    # Opengraph::Metadata with its Fetching concern. The attributes are kept in
    # the order they were first assigned, which is the order `render json:`
    # (instance_values) emits them.
    class Metadata
      TWITTER_HOSTS = %w[twitter.com www.twitter.com x.com www.x.com].freeze
      FX_TWITTER_HOST = "fxtwitter.com"
      ALLOWED_IMAGE_CONTENT_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
      # The validation context and the (empty) errors, which valid? leaves behind.
      VALIDATION_TAIL = '"context_for_validation":{"context":null},"errors":{}}'

      class << self
        def from_url(url)
          found = Document.opengraph_attributes(fetch_document(url))
          attributes = found.dup
          attributes["url"] = valid_canonical_url(found["url"], url)
          attributes["image"] = valid_image_content_type(found["image"])
          new(attributes)
        end

        private

        # Tweets are read through fxtwitter.com; one whose page can't be read
        # raises (nil.force_encoding), as Rails does.
        def fetch_document(url)
          if tweet_url?(url)
            Location.new(replace_twitter_domain(url)).read_html.force_encoding(Encoding::UTF_8)
          else
            Location.new(url).read_html
          end
        end

        def tweet_url?(url)
          uri = URI.parse(url)
          TWITTER_HOSTS.include?(uri.host) && !Opengraph.blank?(uri.path) && uri.path != "/"
        rescue URI::InvalidURIError
          nil
        end

        def replace_twitter_domain(url)
          uri = URI.parse(url)
          uri.host = FX_TWITTER_HOST if TWITTER_HOSTS.include?(uri.host)
          uri.to_s
        rescue URI::InvalidURIError
          nil
        end

        def valid_canonical_url(url, fallback)
          Location.new(url).valid? ? url : fallback
        end

        # Kept only when a HEAD says it's a JPEG, PNG, GIF or WebP.
        def valid_image_content_type(image)
          return nil if Opengraph.blank?(image)
          content_type = Location.new(URI.parse(image)).fetch_content_type&.downcase
          ALLOWED_IMAGE_CONTENT_TYPES.include?(content_type) ? image : nil
        rescue StandardError => e
          raise unless Opengraph.swallow?(e)
          Opengraph.warn("Failed to fetch image content tpye: #{image} (#{e})")
          nil
        end
      end

      def initialize(attributes)
        @attributes = attributes
      end

      def [](key) = @attributes[key]

      # before_validation sanitizes the title and description; then presence of
      # title, url and description, and a valid location for a present image
      # (every validation runs).
      def valid?
        @attributes["title"] = self.class.sanitize_field(@attributes["title"])
        @attributes["description"] = self.class.sanitize_field(@attributes["description"])
        valid = !Opengraph.blank?(self["title"]) && !Opengraph.blank?(self["url"]) && !Opengraph.blank?(self["description"])
        image = self["image"]
        valid = false if !Opengraph.blank?(image) && !Location.new(image).valid?
        valid
      end

      def to_json
        out = +"{"
        @attributes.each { |key, value| out << '"' << key << '":' << RailsCompat::Util.as_json_encode(value) << "," }
        out << VALIDATION_TAIL
      end

      # sanitize(strip_tags(value))
      def self.sanitize_field(value)
        value && RichText::Sanitizer.sanitize_string(strip_tags(value))
      end

      # Rails::HTML5::FullSanitizer: the fragment's text, serialized as one text node.
      def self.strip_tags(html)
        return html if html.empty?
        text = RichText::DOM.text_content(RichText::DOM.parse(html))
        text.match?(RichText::DOM::TEXT_ESCAPE) ? text.gsub(RichText::DOM::TEXT_ESCAPE, RichText::DOM::ESCAPES) : text
      end
    end
  end
end
