# frozen_string_literal: true

module Campfire
  # Base view helpers. Every helper appends to the controller's @b buffer and
  # returns nil, so `<%= helper(...) %>` (which skips nil) and `<% helper %>`
  # behave the same. Templates prefer literal HTML; helpers exist for the
  # dynamic bits and reproduce Rails' tag serialization exactly:
  # attribute order is insertion order, `data:`/`aria:` hashes expand in place
  # (underscores become dashes), boolean attributes render as `x="x"`, nil and
  # false are omitted, arrays are space-joined, values are HTML-escaped.
  module Helpers
    BOOLEAN_ATTRIBUTES = %w[
      allowfullscreen allowpaymentrequest async autofocus autoplay checked compact controls declare default
      defaultchecked defaultmuted defaultselected defer disabled enabled formnovalidate hidden indeterminate
      inert ismap itemscope loop multiple muted nohref nomodule noresize noshade novalidate nowrap open
      pauseonexit playsinline readonly required reversed scoped seamless selected sortable truespeed
      typemustmatch visible
    ].to_h { |a| [a.to_sym, a] }.freeze

    # html_escape that appends; no allocation when nothing needs escaping.
    def h(value)
      @b << ERB::Escape.html_escape(value) unless value.nil?
      nil
    end

    def raw(value)
      @b << value unless value.nil?
      nil
    end

    def attrs(hash)
      hash.each do |k, v|
        next if v.nil?
        if k == :data || k == :aria
          prefix = k == :data ? "data-" : "aria-"
          v.each do |dk, dv|
            next if dv.nil?
            @b << " " << prefix << dashed(dk) << '="'
            @b << ERB::Escape.html_escape(dv.is_a?(String) || dv.is_a?(Symbol) || dv.is_a?(Integer) ? dv.to_s : JSON.generate(dv)) << '"'
          end
        elsif (name = BOOLEAN_ATTRIBUTES[k])
          @b << " " << name << '="' << name << '"' if v
        elsif v == false
          next
        else
          @b << " " << (k.is_a?(Symbol) ? dashed_attr(k) : k) << '="'
          @b << ERB::Escape.html_escape(v.is_a?(Array) ? v.compact.join(" ") : v.to_s) << '"'
        end
      end
      nil
    end

    def tag(name, attributes = nil, close: false)
      @b << "<" << name
      attrs(attributes) if attributes
      @b << (close ? " />" : ">")
      nil
    end

    def content_tag(name, attributes = nil)
      tag(name, attributes)
      yield
      @b << "</" << name << ">"
      nil
    end

    # Rails image_tag: caller options first, then src/width/height.
    def image_tag(logical, size: nil, **opts)
      opts[:src] = Assets.path(logical)
      if size
        w, _, hgt = size.to_s.partition("x")
        opts[:width] = w
        opts[:height] = hgt.empty? ? w : hgt
      end
      tag("img", opts, close: true)
    end

    def asset_path(logical) = Assets.path(logical)

    # dom_id(record, prefix): "message_<client id>", "rooms_closed_<id>" ...
    def dom_id(record, prefix = nil)
      key = record.dom_key
      prefix ? "#{prefix}_#{key}" : key
    end

    private

    def dashed(k) = k.is_a?(String) ? k.tr("_", "-") : DASHED_SYMBOLS.fetch(k) { k.to_s.tr("_", "-") }
    def dashed_attr(k) = k.name.include?("_") ? dashed(k) : k.name
  end

  # Underscored symbols seen in templates; avoids a tr + allocation per use.
  Helpers::DASHED_SYMBOLS = %i[
    controller action target turbo_frame turbo_action turbo_stream turbo_method turbo_confirm turbo_permanent
    turbo_prefetch messages_target reply_target composer_target popup_target search_results_target
    refresh_room_target sorted_list_target local_time_target
  ].to_h { |s| [s, s.to_s.tr("_", "-").freeze] }.freeze
end
