# frozen_string_literal: true

module Campfire
  module RichText
    # One render context (host, user resolver, sgid verifier). Mirrors Action
    # Text's Content/Attachment rendering plus Campfire's content filters,
    # attachables and views; see Campfire::RichText for the public entry points.
    class Renderer
      include HTML5
      Node = HTML5::Node
      E = ERB::Escape

      ATTACHMENT = "action-text-attachment"
      ATTRIBUTE_ORDER = %w[sgid content-type url href filename filesize width height previewable presentation caption content].freeze
      MENTION = "application/vnd.campfire.mention"
      OPENGRAPH = "application/vnd.actiontext.opengraph-embed"
      OPENGRAPH_RE = /application\/vnd.actiontext.opengraph-embed/ # String#match semantics: dots are wildcards
      TWITTER_AVATAR = "https://pbs.twimg.com/profile_images"
      TWITTER_DOMAINS = %w[x.com twitter.com].freeze
      MISSING = "☒"
      WRAP_OPEN = %(<div class="lexxy-content">\n  )
      WRAP_CLOSE = "\n</div>\n"
      BLANK = /\A[[:space:]]*\z/
      JSON_ESCAPES = Ractor.make_shareable(%W[< > & \u2028 \u2029].to_h { |c| [c, format("%cu%04x", 92, c.ord)] })
      JSON_UNSAFE = /[<>&\u2028\u2029]/
      TRIX_KEYS = %w[data-trix-attachment data-trix-attributes].freeze

      def initialize(host, resolver, verifier = nil)
        @host = host.to_s
        @resolver = resolver
        @verifier = verifier
      end

      # -- entry points ------------------------------------------------------

      def plain_text(body)
        root = load(body)
        plain(root)
      end

      def body_html(body) = body_html_from(load(body))

      # ActionText::Content.new(body, canonicalize: true).to_html: what assigning a
      # String to a rich text attribute stores.
      def canonical(body) = DOM.serialize(load(body))

      def filtered(body)
        root = load(body)
        filter(root.deep_clone, plain(root))[2]
      end

      def presentation(body)
        root = load(body)
        present(*filter(root.deep_clone, plain(root)))
      end

      def mentioned_user_ids(body) = mentions(load(body))

      def render(body)
        r = Result.new(nil, nil, nil, nil, nil, nil, {})
        r.editable = capture(r, :editable) { editable(body) }
        root = capture(r, :plain_text) { load(body) }
        unless root
          %i[filtered body_html mentioned_user_ids].each { |f| r.errors[f] = r.errors[:plain_text] }
          r.presentation = ""
          return r
        end
        r.plain_text = capture(r, :plain_text) { plain(root.deep_clone) }
        capture(r, :body_html) { r.body_html = body_html_from(root.deep_clone) }
        if (e = r.errors[:plain_text])
          r.errors[:filtered] = e
          r.presentation = ""
        else
          f = capture(r, :filtered) { filter(root.deep_clone, r.plain_text) }
          r.filtered = f[2] if f
          r.presentation = (f && (present(*f) rescue nil)) || ""
        end
        capture(r, :mentioned_user_ids) { r.mentioned_user_ids = mentions(root) }
        r
      end

      # Lexxy's editable_body: every attachment rebuilt from its attachable, then
      # Lexxy's as_editable pass JSON-encodes the content of non-url attachments.
      def editable(body)
        root = DOM.parse(body.strip)
        2.times do |pass|
          root = DOM.parse(DOM.serialize(root)) if pass == 1
          DOM.walk(root) do |n|
            next unless attachment?(n) && n.parent
            next if pass == 1 && !n["url"].to_s.strip.empty?
            markup, ct = attachment(n, false, 0)
            if markup == MISSING
              n.parent.remove(n)
              next
            end
            raise Error, "NoMethodError: attachable_content_type" unless ct == MENTION || OPENGRAPH_RE.match?(ct)
            n["content-type"] = ct
            n["content"] = pass == 1 ? to_json(markup) : markup
          end
        end
        out = DOM.serialize(root)
        out.strip.empty? ? nil : out
      end

      private

      def capture(result, field)
        yield
      rescue Error => e
        result.errors[field] ||= e
        nil
      end

      def body_html_from(root)
        rendered = replace_attachments(root, false) + galleries(root, true)
        tree = reparse(root, rendered.zero? && @source)
        wrap(DOM.serialize(Sanitizer.sanitize(tree, :action)))
      end

      # parse(serialize(tree)). The reparse is skipped when +tree+ is known to be
      # the unmodified parse of +source+ and serializes back to it: canonicalizing
      # and sanitizing only ever remove or rename, which always shows in the markup.
      def reparse(tree, source, html = DOM.serialize(tree))
        source && html == source ? tree : DOM.parse(html)
      end

      def wrap(html) = "#{WRAP_OPEN}#{html}#{WRAP_CLOSE}"

      def plain(root)
        replace_attachments(root, true)
        PlainText.convert(root)
      end

      # ContentFilters::TextMessagePresentationFilters, then re-parsed (the
      # filtered body as stored for rendering).
      # Returns [tree, the markup it was parsed from, its serialization].
      def filter(root, plain_text)
        solo = remove_solo_unfurled_link_text(root, plain_text)
        sanitize_tags(root)
        Sanitizer.sanitize(root, :filter)
        html = DOM.serialize(root).strip
        return [root, html, html] if !solo && html == @source
        tree = DOM.parse(html)
        [tree, html, DOM.serialize(tree)]
      end

      # Action Text render + sanitize, then auto_link with its own sanitize.
      def present(tree, source, html)
        rendered = replace_attachments(tree, false) + galleries(tree, true)
        tree = rendered.zero? ? reparse(tree, source == html && source) : DOM.parse(DOM.serialize(tree))
        page = Sanitizer.sanitize(DOM.parse(wrap(DOM.serialize(Sanitizer.sanitize(tree, :action)))), :auto)
        Autolink.call(DOM.serialize(page, true))
      end

      def mentions(root)
        ids = []
        return ids unless @verifier
        DOM.walk(root) do |n|
          next unless attachment?(n) && (sgid = n["sgid"]) && !sgid.empty?
          id = SGID.user_id(@verifier.call(sgid)) or next
          user = find_user(id) or next
          ids << user.id unless ids.include?(user.id)
        end
        ids
      end

      def find_user(id)
        return unless @resolver
        @resolver.respond_to?(:find_user) ? @resolver.find_user(id) : @resolver.call(id)
      end

      def attachment?(n) = n.type == ELEMENT && n.data == ATTACHMENT

      # -- canonicalization (ActionText::Content.new) -------------------------

      # The top-level body; remembers its markup for #reparse.
      def load(body) = canonicalize(DOM.parse(@source = body.strip))

      def canonicalize(root)
        DOM.walk(root) do |n|
          next unless n.type == ELEMENT
          if (trix = n["data-trix-attachment"]) && !trix.empty?
            next unless trix_attachment(n)
          end
          n.children.clear if n.data == ATTACHMENT
        end
        galleries(root, false)
        root
      end

      # Converts a Trix <figure data-trix-attachment> into an attachment node;
      # returns false when it carried no attributes and was dropped.
      def trix_attachment(n)
        data = {}
        TRIX_KEYS.each do |key|
          value = trix_json(n[key])
          next if value.nil? || value == false
          raise Error, "NoMethodError: merge" unless value.is_a?(Hash)
          data.merge!(value)
        end
        attrs = []
        ATTRIBUTE_ORDER.each do |name|
          key = name == "content-type" ? "contentType" : name
          attrs << name << data[key].to_s << nil if data.key?(key)
        end
        if attrs.empty?
          n.parent.remove(n)
          return false
        end
        n.data = ATTACHMENT
        n.attrs = attrs
        true
      end

      def trix_json(s)
        return if s.nil? || s.empty?
        JSON.parse(s, allow_comments: true, allow_duplicate_key: true)
      rescue JSON::ParserError
        nil
      end

      # ActionText::AttachmentGallery: a div holding only gallery attachments.
      def galleries(root, render)
        count = 0
        DOM.walk(root) do |n|
          next unless n.type == ELEMENT && n.data == "div"
          members = []
          next unless n.children.all? do |c|
            if c.type == TEXT && c.data.delete("\n ").empty? then true
            elsif attachment?(c) && c["presentation"] == "gallery" then members << c
            end
          end
          next if members.size < 2
          count += 1
          n.attrs = nil
          next unless render
          n["class"] = "attachment-gallery attachment-gallery--#{members.size}"
          html = +"\n  "
          members.each { |c| html << DOM.serialize(c) }
          DOM.inner(n, html << "\n")
        end
        count
      end

      # -- attachment rendering ----------------------------------------------

      # Returns the number of attachments replaced.
      def replace_attachments(root, as_plain, depth = 0)
        count = 0
        DOM.walk(root) do |n|
          next unless attachment?(n) && n.parent
          count += 1
          if (value = n["content"]) && !value.empty?
            sanitized = DOM.serialize(Sanitizer.sanitize(DOM.parse(value), :action))
            n.delete_attr("content")
            n["content"] = sanitized unless sanitized.match?(BLANK)
          end
          markup, = attachment(n, as_plain, depth)
          next DOM.replace(n, markup) if as_plain
          attrs = []
          ATTRIBUTE_ORDER.each { |key| (v = n[key]) && (attrs << key << v << nil) }
          raise Error, "NoMethodError: node for nil" if attrs.empty?
          full = Node.new(ELEMENT, ATTACHMENT, attrs)
          DOM.inner(full, markup)
          DOM.replace(n, DOM.serialize(full))
        end
        count
      end

      # Returns [markup, attachable content type] following
      # ActionText::Attachment.from_node with Campfire's attachables.
      def attachment(n, as_plain, depth)
        ct = n["content-type"].to_s
        caption = n["caption"].to_s
        if OPENGRAPH_RE.match?(ct)
          markup = opengraph_embed(n)
          return [as_plain ? "" : markup, OPENGRAPH]
        end
        sgid = n["sgid"]
        if sgid && !sgid.empty? && (id = SGID.unverified_user_id(sgid)) && (user = find_user(id))
          n["content-type"] = MENTION
          return [as_plain ? "@#{user.name}" : mention(user), MENTION]
        end
        content = n["content"].to_s
        if ct.include?("html") && !content.match?(BLANK)
          return ["", ct] if depth >= 8
          nested = canonicalize(DOM.parse(content.strip))
          return [DOM.serialize(nested), ct] if as_plain
          replace_attachments(nested, false, depth + 1)
          Sanitizer.sanitize(nested, :action)
          return ["<figure class=\"attachment attachment--content\">\n  #{DOM.serialize(nested)}\n\n</figure>", ct]
        end
        src = n["url"].to_s
        if !src.empty? && (ct.start_with?("image/", "video/") || ct == "image" || ct == "video")
          return [remote_media(n, src, ct, caption, as_plain), ct]
        end
        [as_plain ? caption : MISSING, ct]
      end

      def remote_media(n, src, ct, caption, as_plain)
        video = ct.start_with?("video")
        if as_plain
          label = caption.empty? ? (video ? (n["filename"].to_s.empty? ? "Video" : n["filename"]) : "Image") : caption
          return "[#{label}]"
        end
        size = +""
        %w[width height].each { |k| (v = n[k]) && !v.empty? && size << " #{k}=\"#{E.html_escape(v)}\"" }
        unless src.start_with?("/", "cid:", "data:") || src.include?("://")
          raise Error, "raised Propshaft::MissingAssetError"
        end
        html = if video
          +%(<figure class="attachment attachment--preview attachment--video">\n  <video controls="controls"#{size}>\n    <source src="#{E.html_escape(src)}" type="#{E.html_escape(ct)}">\n</video>)
        else
          +%(<figure class="attachment attachment--preview">\n  <img#{size} src="#{E.html_escape(src)}" />\n)
        end
        html << %(    <figcaption class="attachment__caption">\n      #{E.html_escape(caption)}\n    </figcaption>\n) unless caption.empty?
        html << "</figure>"
      end

      # app/models/user/mentionable.rb's attachable partial.
      def mention(user)
        %(<span class="mention" sgid="#{E.html_escape(user.attachable_sgid.to_s)}"><a title="#{E.html_escape(user.title.to_s)}" class="btn avatar" data-turbo-frame="_top" href="#{E.html_escape(user.user_path.to_s)}"><img aria-hidden="true" src="#{E.html_escape(user.avatar_path.to_s)}" width="48" height="48" /></a> #{E.html_escape(user.name.to_s)}</span>)
      end

      # -- opengraph embeds (lib/rails_ext/actiontext_opengraph_embeds.rb) -----

      def opengraph_attributes(n)
        filename = n["filename"]
        if filename && !filename.match?(BLANK)
          [web_url(n["href"]), web_url(n["url"]), filename, n["caption"]]
        else
          root = DOM.parse(n["content"].to_s)
          title = first(root) { |e| DOM.classes?(e, "og-embed__title") }
          link = title && first(title) { |e| e.data == "a" }
          image = first(root) { |e| e.data == "img" && ancestor_class?(e, root, "og-embed__image") }
          description = first(root) { |e| DOM.classes?(e, "og-embed__description") }
          [web_url(link&.[]("href")), web_url(image&.[]("src")),
            (link || title) && DOM.text_content(link || title).strip,
            description && DOM.text_content(description).strip]
        end
      end

      def opengraph_embed(n)
        href, url, filename, description = opengraph_attributes(n)
        title = filename && E.html_escape(truncate(filename, 280))
        if href
          title = %(<a rel="noreferrer" target="_blank" href="#{E.html_escape(href)}">#{title || E.html_escape(href)}</a>)
        end
        avatar = url.to_s.start_with?(TWITTER_AVATAR) ? "og-embed--twitter-avatar" : ""
        html = +%(<figure class="attachment attachment--content attachment--og">\n  <actiontext-opengraph-embed>\n    <div class="og-embed gap #{avatar}">\n      <div class="og-embed__content">\n        <div class="og-embed__title">\n          #{title}\n        </div>\n        <div class="og-embed__description">#{E.html_escape(truncate(description.to_s, 560))}</div>\n      </div>\n)
        html << %(        <div class="og-embed__image">\n          <img src="#{E.html_escape(url)}" class="image center" alt="">\n        </div>\n) if url
        html << "    </div>\n  </actiontext-opengraph-embed>\n</figure>"
      end

      def truncate(s, length)
        s.length > length ? "#{s[0, length - 1]}…" : s
      end

      def first(node, &block)
        DOM.each_element(node) { |e| return e if yield(e) }
        nil
      end

      def ancestor_class?(e, root, name)
        p = e.parent
        while p && !p.equal?(root)
          return true if p.type == ELEMENT && DOM.classes?(p, name)
          p = p.parent
        end
        false
      end

      def web_url(value)
        return if value.nil? || value.match?(BLANK)
        parsed = URI.parse(value)
        value if parsed.is_a?(URI::HTTP) && elsewhere?(parsed.host)
      rescue URI::InvalidURIError
        nil
      rescue URI::Error => e
        raise Error, "raised #{e.class}"
      end

      def elsewhere?(host)
        return false unless host && !host.match?(BLANK) && !host.include?("%") && host.include?(".")
        label = host.split(".").last or raise Error, "raised NoMethodError: match?"
        return false unless label.match?(/[a-z]/i) && !label.match?(/\A0x/i)
        canonical_host(host) != canonical_host(@host)
      end

      def canonical_host(host) = host.downcase.delete_suffix(".")

      # -- ContentFilters ------------------------------------------------------

      def remove_solo_unfurled_link_text(root, plain_text)
        links = []
        DOM.each_element(root) { |e| links << e if e.data == ATTACHMENT && e["content-type"] == OPENGRAPH }
        return unless links.size == 1
        href = opengraph_attributes(links.first).first
        return unless href && normalize_tweet_url(href) == normalize_tweet_url(plain_text)
        divs = []
        DOM.each_element(root) { |e| divs << e if e.data == "div" }
        if divs.any?
          html = DOM.serialize(links.first)
          divs.each { |div| DOM.inner(div, html) }
        else
          paragraphs = []
          DOM.each_element(root) { |e| paragraphs << e if e.data == "p" }
          paragraphs.each { |p| p.detach unless first(p) { |e| e.data == ATTACHMENT } }
        end
        true
      end

      def normalize_tweet_url(url)
        return url unless url && !url.match?(BLANK) && TWITTER_DOMAINS.any? { |d| url.strip.include?(d) }
        uri = URI.parse(url)
        u = uri.dup
        u.host = (uri.host&.downcase == "x.com" ? "twitter.com" : uri.host)
        u.query = nil
        u.to_s
      rescue URI::InvalidURIError
        url
      rescue URI::Error => e
        raise Error, "raised #{e.class}"
      end

      ALLOWED_TAGS = Ractor.make_shareable(Sanitizer::DEFAULT_TAGS.merge(Sanitizer::FILTER_TAGS).except("img"))

      def sanitize_tags(root)
        DOM.walk(root) do |n|
          n.parent.remove(n) if n.type == ELEMENT && n.parent && !ALLOWED_TAGS[n.data]
        end
      end

      def to_json(s)
        json = JSON.generate(s)
        json.match?(JSON_UNSAFE) ? json.gsub(JSON_UNSAFE, JSON_ESCAPES) : json
      end
    end
  end
end
