# frozen_string_literal: true

module Campfire
  # MessagesHelper + Messages::AttachmentPresentation + RichTextHelper bits.
  module Helpers
    THUMBNAIL_MAX_WIDTH = 1200
    THUMBNAIL_MAX_HEIGHT = 800
    THUMB_VARIATION = { "format" => "jpg", "resize_to_limit" => [THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT] }.freeze

    MESSAGES_ACTIONS = "turbo:before-stream-render@document-&gt;messages#beforeStreamRender keydown.up@document-&gt;messages#editMyLastMessage dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop visibilitychange@document-&gt;presence#visibilityChanged"

    # <div id="message-area" ...> opening tag (message_area_tag).
    def message_area_open_tag(room)
      @b << %(<div id="message-area" class="message-area" contents="true" data-controller="messages presence drop-target" data-action=") <<
        MESSAGES_ACTIONS << %(" data-messages-first-of-day-class="message--first-of-day" data-messages-formatted-class="message--formatted" data-messages-me-class="message--me" data-messages-mentioned-class="message--mentioned" data-messages-threaded-class="message--threaded" data-messages-page-url-value=")
      h(base_url)
      @b << "/rooms/" << room.id_s << %(/messages">)
      nil
    end

    # <div id="messages_rooms_open_1" class="messages" ...> opening tag (messages_tag).
    def messages_open_tag(room)
      @b << '<div id="messages_' << room.dom_key << %(" class="messages" data-controller="maintain-scroll refresh-room" data-action="turbo:before-stream-render@document-&gt;maintain-scroll#beforeStreamRender visibilitychange@document-&gt;refresh-room#visibilityChanged online@window-&gt;refresh-room#online" data-messages-target="messages" data-refresh-room-loaded-at-value=") <<
        Clock.epoch_ms(room.updated_at).to_s << '" data-refresh-room-url-value="'
      h(base_url)
      @b << "/rooms/" << room.id_s << %(/refresh">)
      nil
    end

    # Renders a page of messages (render partial: "messages/message",
    # collection:, cached: true). `page` is a Message::Page: ids and cache
    # versions; full rows are loaded in one batch for fragment misses only.
    def render_messages(page, room)
      n = page.size
      return nil if n.zero?
      ids = page.ids
      versions = page.versions
      hits = Array.new(n)
      misses = nil
      i = 0
      while i < n
        if (f = Cache.peek_fragment(:message, ids[i], versions[i]))
          hits[i] = f
        else
          (misses ||= []) << ids[i]
        end
        i += 1
      end
      if misses
        loaded = Message.load_presentation(@db, misses)
        room_name = room_display_name(room, nil)
        i = 0
        while i < n
          unless hits[i]
            m = loaded[ids[i]]
            hits[i] = m ? cached_message(m.context!(host_without_port, user_resolver), room_name) : ""
          end
          i += 1
        end
      end
      hits.each { |f| PageParts.record(@b, f); @b << f }
      nil
    end

    # One message through the fragment cache (cache [message, "presentation-v3"]).
    def cached_message(message, room_name)
      Cache.fragment(:message, message.id, Message.version(message.updated_at)) do
        capture do
          if message.unrenderable?
            @b << "\n  "
            _messages_unrenderable
          else
            _messages_message(message: message, room_name: room_name)
          end
        end
      end
    end

    # cache boost do ... end around messages/boosts/_boost. Boosts first
    # rendered by a broadcast keep that render (no form token) everywhere.
    def cached_boost(boost)
      Cache.fragment(:boost, boost.id, boost.updated_at) { capture { _messages_boosts_boost(boost: boost) } }
    end

    def render_message(message, room_name)
      @b << cached_message(message, room_name)
      nil
    end

    # message_presentation(message)
    def message_presentation(message)
      if (blob = message.attachment)
        message_attachment_presentation(message, blob)
      elsif (sound = message.sound)
        message_sound_presentation(sound)
      else
        @b << message.presentation(host_without_port, user_resolver)
      end
      nil
    rescue => e
      Log.error("message presentation failed", e)
      nil
    end

    def message_sound_presentation(sound)
      @b << %(<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value=") <<
        Assets.path(sound.asset_path) << %("><button class="btn btn--plain" data-action="sound#play">🔊</button>)
      if (img = sound.image)
        @b << '<img width="' << img.width.to_s << '" height="' << img.height.to_s << '" class="align--middle" src="' << Assets.path(img.asset_path) << '" />'
      else
        h(sound.text)
      end
      @b << "</div>"
      nil
    end

    # Messages::AttachmentPresentation#render
    def message_attachment_presentation(message, blob)
      if blob.previewable? || blob.variable?
        width, height = preview_dimensions(blob)
        if width && height
          @b << '<div class="max-inline-size center flex overflow-clip" style="width: ' << (width / 2).to_s << "px; aspect-ratio: " << (width / height.to_f).to_s << ';">'
        else
          @b << '<div class="max-inline-size center overflow-clip">'
        end
        if blob.video?
          @b << '<video src="'
          h(blob_path(blob))
          @b << '" poster="'
          h(representation_path(blob, preview: true))
          @b << '" controls="controls" preload="none" width="100%" height="100%" class="message__attachment"></video>'
        else
          @b << '<a class="flex" data-lightbox-target="image" data-action="lightbox#open" data-lightbox-url-value="'
          h(blob_path(blob, disposition: "attachment"))
          @b << '" href="'
          h(blob_path(blob))
          @b << '"><img'
          @b << ' width="' << width.to_s << '"' if width
          @b << ' height="' << height.to_s << '"' if height
          @b << ' class="message__attachment" loading="lazy" src="'
          h(representation_path(blob))
          @b << '" /></a>'
        end
        @b << "</div>"
      else
        download = blob_path(blob, disposition: "attachment")
        @b << '<div class="flex-inline align-center gap-half"><img class="colorize--black" aria-hidden="true" src="' << Assets.path("common-file-text.svg") <<
          '" width="22" height="22" /><span>'
        h(blob.filename)
        @b << '</span><a class="btn message__action-btn hide-in-ios-pwa" style="--width: auto;" href="'
        h(download)
        @b << '"><img aria-hidden="true" src="' << Assets.path("download.svg") << '" width="20" height="20" /><span class="for-screen-reader">Download '
        h(blob.filename)
        @b << '</span></a><button class="btn message__action-btn" style="--width: auto;" data-controller="web-share" data-action="web-share#share" data-web-share-files-value="'
        h(download)
        @b << '"><img aria-hidden="true" src="' << Assets.path("share.svg") << '" width="20" height="20" /><span class="for-screen-reader">Share '
        h(blob.filename)
        @b << "</span></button></div>"
      end
      nil
    end

    def preview_dimensions(blob)
      width = blob.width
      height = blob.height
      if width.nil? || height.nil?
        [nil, nil]
      elsif width <= THUMBNAIL_MAX_WIDTH && height <= THUMBNAIL_MAX_HEIGHT
        [width, height]
      else
        scale = [THUMBNAIL_MAX_WIDTH.to_f / width, THUMBNAIL_MAX_HEIGHT.to_f / height].min
        [width * scale, height * scale]
      end
    end

    # rails_blob_path(blob, disposition:, only_path: true)
    def blob_path(blob, disposition: nil) = Storage.blob_path(blob, disposition: disposition)

    # url_for(blob.representation(:thumb)) / blob.preview(format: :webp, ...)
    def representation_path(blob, preview: false)
      preview ? Storage.preview_path(blob, Storage::VIDEO_POSTER) : Storage.representation_path(blob, Storage::THUMB)
    end

    def host_without_port
      @host_without_port ||= begin
        h = host_with_port.to_s
        if h.start_with?("[")
          h[0, (h.index("]") || h.size - 1) + 1]
        else
          (i = h.index(":")) ? h[0, i] : h
        end
      end
    end

    # The URL base broadcast renders use inside a request: default_url_options
    # from SetCurrentRequest (request protocol + host, port dropped).
    def renderer_base_url = "#{scheme}://#{host_without_port}"

    # Rich text attachable lookup (mentions); memoized per request.
    def user_resolver
      @user_resolver ||= Message.user_resolver(@db)
    end

    def all_emoji?(string) = RichText.all_emoji?(string)

    # RichTextHelper#editable_body (the lexxy-editor value on messages/edit).
    def editable_body(message)
      message.body ? RichText.editable(message.body, host: host_without_port, resolver: user_resolver) : ""
    end
  end
end
