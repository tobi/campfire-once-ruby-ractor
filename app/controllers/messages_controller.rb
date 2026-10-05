# frozen_string_literal: true

module Campfire
  # MessagesController (RoomScoped). index renders without a layout; show and
  # edit render the full application layout (upstream's `layout false, only:
  # :index` also disables turbo-rails' frame layout for the other actions).
  class MessagesController < ApplicationController
    CACHE_CONTROL = "max-age=0, private, must-revalidate"

    # GET /rooms/:room_id/messages(?before=|?after=)
    def index
      set_room!
      page =
        if (before = present_param("before"))
          Message.page_before(@db, @room.id, find_message!(before).created_at)
        elsif (after = present_param("after"))
          Message.page_after(@db, @room.id, find_message!(after).created_at)
        else
          Message.last_page(@db, @room.id)
        end
      return head(204) if page.empty?
      return head(304) if fresh_page?(page)
      html { render_messages(page, @room); @b << "\n" }
    end

    # POST /rooms/:room_id/messages
    def create
      @room = Room.find_for_user(@db, current_user.id, params["room_id"].to_i)
      return html { layout { messages_room_not_found } } unless @room
      attrs = params["message"]
      attrs = {} unless attrs.is_a?(Hash)
      message = create_message(attrs)
      fragment = deliver_created(message)
      turbo_stream { @b << turbo_stream_tag("append", "messages_#{@room.dom_key}", fragment) << "\n" }
    end

    # GET /rooms/:room_id/messages/:id
    def show
      set_room!
      message = set_message!
      html { layout { @b << message_fragment(message) << "\n"; nil } }
    end

    # GET /rooms/:room_id/messages/:id/edit
    def edit
      set_room!
      message = set_message!
      ensure_can_administer(message)
      message = Message.load_one(@db, message.id).context!(host_without_port, user_resolver)
      mpath = message_path(message)
      html { layout { messages_edit(message: message, mpath: mpath) } }
    end

    # PATCH/PUT /rooms/:room_id/messages/:id
    def update
      set_room!
      message = set_message!
      ensure_can_administer(message)
      attrs = params["message"]
      body = attrs.is_a?(Hash) ? attrs["body"] : nil
      message.update_body!(@db, body.to_s) if body
      message = broadcast_replace(message)
      redirect_to(message_path(message))
    end

    # DELETE /rooms/:room_id/messages/:id
    def destroy
      set_room!
      message = set_message!
      ensure_can_administer(message)
      remove = destroy_and_broadcast(message)
      turbo_stream { @b << remove << "\n" }
    end

    private

    # @message.broadcast_create + deliver_webhooks_to_bots (plus Room#receive, the
    # after_create_commit). Returns the rendered message partial.
    def deliver_created(message)
      Delivery.receive(@room, message)
      # broadcast_create renders (and caches) the partial with
      # ApplicationController.renderer; create.turbo_stream reuses that entry.
      fragment = MessageBroadcasts.fragment(@db, @room, message, host_without_port, renderer_base_url)
      broadcast_to(room_stream(@room), turbo_stream_tag("append", "messages_#{@room.dom_key}", fragment))
      Delivery.broadcast_unread_room(@db, @room)
      Delivery.deliver_webhooks(@db, @room, message)
      fragment
    end

    # broadcast_replace_to @room, :messages, target: [@message, :presentation],
    # partial: "messages/presentation". Returns the reloaded message.
    def broadcast_replace(message)
      message = Message.load_one(@db, message.id).context!(host_without_port, user_resolver)
      presentation = capture { _messages_presentation(message: message) }
      broadcast_to(room_stream(@room), turbo_stream_tag("replace", "presentation_message_#{message.client_message_id}", presentation, maintain_scroll: true))
      message
    end

    # @message.destroy + broadcast_remove. Returns the remove stream tag.
    def destroy_and_broadcast(message)
      message.destroy!(@db)
      remove = turbo_stream_tag("remove", "message_#{message.client_message_id}")
      broadcast_to(room_stream(@room), remove)
      remove
    end

    # RoomScoped#set_room: Current.user.memberships.find_by!(room_id:) -> 404.
    def set_room!
      @room = Room.find_for_user(@db, current_user.id, params["room_id"].to_i)
      not_found! unless @room
    end

    def set_message! = find_message!(params["id"])

    def find_message!(id)
      Message.find_in_room(@db, @room.id, id) || not_found!
    end

    def present_param(name)
      v = params[name]
      v.is_a?(String) && !v.strip.empty? ? v : nil
    end

    def message_path(message) = "/rooms/#{message.room_id}/messages/#{message.id}"

    # The message partial through the fragment cache, for responses and broadcasts.
    # Rows are loaded (load_one) only on a cache miss unless `full` is given.
    def message_fragment(message, full = nil)
      Cache.peek_fragment(:message, message.id, Message.version(message.updated_at)) || begin
        full ||= Message.load_one(@db, message.id)
        cached_message(full.context!(host_without_port, user_resolver), room_display_name(@room, nil))
      end
    end

    # fresh_when @messages: weak ETag over the page's ids and versions plus
    # Last-Modified from the newest updated_at (see report: the Rails ETag
    # digests the template tree and cannot be reproduced byte-for-byte).
    def fresh_page?(page)
      newest = page.versions.max
      last_modified = Time.at(newest / 1_000_000, newest % 1_000_000, :usec).utc
      etag = %(W/"#{Digest::MD5.hexdigest("#{current_user.id}/#{page.ids.join(",")}/#{page.versions.join(",")}")}")
      add_header("etag", etag)
      add_header("last-modified", last_modified.httpdate)
      add_header("cache-control", CACHE_CONTROL)
      if (inm = header("if-none-match")&.to_s)
        inm.split(",").any? { |t| t.strip == etag || t.strip == "*" }
      elsif (ims = header("if-modified-since")&.to_s)
        (Time.httpdate(ims) rescue nil)&.then { |t| last_modified.to_i <= t.to_i } || false
      else
        false
      end
    end

    # room.messages.create_with_attachment!(message_params). The body is
    # stored as submitted (Lexxy already sends Action Text markup; RichText's
    # body_html is the *rendered* form, wrapped in div.lexxy-content, so
    # storing it would double-wrap the presentation); RichText.render runs
    # once (plain text for the search index, presentation for the first
    # render; Delivery parses mentions for webhooks). The attachment is stored,
    # attached and processed synchronously.
    def create_message(attrs)
      body = attrs["body"]
      body = nil unless body.is_a?(String)
      upload = attrs["attachment"]
      upload = nil unless upload.respond_to?(:original_filename)
      rendered = body && render_body(body)
      plain = rendered&.plain_text
      blob = upload && upload.open { |io| Storage.create_blob_from_upload(@db, upload.original_filename, upload.content_type, io) }
      message = Message.create!(@db, @room, current_user, body: body, plain_text: plain, blob: blob,
        client_message_id: attrs["client_message_id"].is_a?(String) ? attrs["client_message_id"] : nil)
      message.rendered!(rendered) if rendered && rendered.errors.empty?
      if blob
        Storage.process_attachment(blob.id) rescue nil
        message.attachment = Storage.find(@db, blob.id) || blob
      end
      message
    ensure
      upload&.unlink if upload.respond_to?(:unlink)
    end

    def render_body(body)
      RichText.render(body, host: host_without_port, resolver: user_resolver, verifier: sgid_verifier)
    end

    def sgid_verifier
      Ractor[:messages_sgid_verifier] ||= RichText::SGID::Verifier.new(Campfire.config.secret_key_base)
    end
  end
end
