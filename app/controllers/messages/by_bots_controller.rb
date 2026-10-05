# frozen_string_literal: true

require_relative "../messages_controller"

module Campfire
  module Messages
    # What the bot API controllers share: RawRequestBody, Rails' `blank?`, and the
    # PublicExceptions response for a RecordNotFound under the route's JSON format.
    module BotApi
      BLANK = /\A[[:space:]]*\z/
      ERROR_TYPE = "application/json; charset=UTF-8"
      NOT_FOUND_JSON = '{"status":404,"error":"Not Found"}'

      private

      # RawRequestBody#raw_request_body: the whole body, tagged UTF-8.
      def raw_request_body = body_string

      def blank?(value)
        case value
        when nil, false then true
        when String then value.match?(BLANK)
        when Hash, Array then value.empty?
        else false
        end
      end

      # ActiveRecord::RecordNotFound -> PublicExceptions renders `request.formats.first`,
      # which the route default makes JSON.
      def not_found!
        return super unless @format == "json"
        @response = Responses.build(404, [["content-type", ERROR_TYPE]], @request.method == "HEAD" ? nil : NOT_FOUND_JSON)
        throw :halt
      end

      # Current.user.rooms.find_by(id: params[:room_id]) || head :not_found
      def set_bot_room!
        @room = Room.find_for_user(@db, current_user.id, params["room_id"].to_i)
        filter_head(404) unless @room
      end
    end

    # Messages::ByBotsController: the bot API under /rooms/:room_id/:bot_key/messages
    # (JSON by route default). Bodies are the raw request body, or a multipart
    # `attachment`.
    class ByBotsController < MessagesController
      include BotApi

      allow_bot_access only: %i[index create update destroy]

      COUNT = "SELECT count(*) FROM messages WHERE room_id = ?"
      CREATED_AT = "SELECT created_at FROM messages WHERE id = ?"
      EXISTS_BEFORE = "SELECT 1 FROM messages WHERE room_id = ? AND created_at < ? LIMIT 1"
      EXISTS_AFTER = "SELECT 1 FROM messages WHERE room_id = ? AND created_at > ? LIMIT 1"
      # Journey::Router::Utils.escape_segment
      SEGMENT_UNSAFE = %r{[^a-zA-Z0-9\-._~!$&'()*+,;=:@]}

      # GET /rooms/:room_id/:bot_key/messages(?before=|?after=)
      def index
        set_bot_room!
        page = find_paged_messages
        add_header("x-total-count", @db.query_single_splat(COUNT.freeze, @room.id).to_s)
        if (next_page = next_page_param(page))
          add_header("link", "<#{base_url}/rooms/#{@room.id}/#{escape_segment(params["bot_key"].to_s)}/messages?#{next_page}>; rel=\"next\"")
        end
        json(messages_json(page))
      end

      # POST /rooms/:room_id/:bot_key/messages
      def create
        set_bot_room!
        attachment = params["attachment"]
        filter_head(422) if blank?(attachment) && blank?(raw_request_body)
        message = create_message(attachment ? { "attachment" => bot_attachment(attachment) } : { "body" => canonical_body(raw_request_body) })
        deliver_created(message)
        add_header("location", "#{base_url}/messages/#{message.id}")
        head(201)
      end

      # PATCH/PUT /rooms/:room_id/:bot_key/messages/:id
      def update
        set_bot_room!
        message = set_message!
        ensure_can_administer(message)
        attachment = params["attachment"]
        if attachment
          replace_attachment(message, bot_attachment(attachment))
        else
          message.update_body!(@db, canonical_body(raw_request_body))
        end
        message = broadcast_replace(message)
        json(message_json(message))
      end

      # DELETE /rooms/:room_id/:bot_key/messages/:id
      def destroy
        set_bot_room!
        message = set_message!
        ensure_can_administer(message)
        destroy_and_broadcast(message)
        head(204)
      end

      private

      # MessagesController#find_paged_messages
      def find_paged_messages
        if (before = present_param("before"))
          Message.page_before(@db, @room.id, find_message!(before).created_at)
        elsif (after = present_param("after"))
          Message.page_after(@db, @room.id, find_message!(after).created_at)
        else
          Message.last_page(@db, @room.id)
        end
      end

      # set_pagination_headers' next_page_params (note: `after` decides the
      # direction even when `before` chose the page).
      def next_page_param(page)
        return if page.empty?
        if present_param("after")
          id = page.last_id
          "after=#{id}" if @db.query_single_splat(EXISTS_AFTER.freeze, @room.id, Message.time_bind(created_at_of(id)))
        else
          id = page.first_id
          "before=#{id}" if @db.query_single_splat(EXISTS_BEFORE.freeze, @room.id, Message.time_bind(created_at_of(id)))
        end
      end

      def created_at_of(id) = @db.query_single_splat(CREATED_AT.freeze, id)

      def escape_segment(s)
        s.match?(SEGMENT_UNSAFE) ? s.b.gsub(SEGMENT_UNSAFE) { |c| format("%%%02X", c.ord) } : s
      end

      # Assigning a String to the rich text body stores its canonical markup.
      def canonical_body(body)
        RichText.canonical(body, host: host_without_port, resolver: user_resolver)
      rescue RichText::Error
        body
      end

      # params.permit(:attachment): an upload, or blank (nothing attached). Anything
      # else is taken as a signed blob id by Active Storage, which raises.
      def bot_attachment(attachment)
        return attachment if attachment.respond_to?(:original_filename)
        return nil if blank?(attachment)
        raise ArgumentError, "Could not find or build blob: expected attachable"
      end

      # @message.update!(attachment:): an upload replaces the attachment (the
      # attachment record touches the message), a blank one removes it.
      def replace_attachment(message, upload)
        if upload
          blob = upload.open { |io| Storage.create_blob_from_upload(@db, upload.original_filename, upload.content_type, io) }
          Storage.attach(@db, blob.id, "Message", message.id, "attachment", analyze: false)
          message.touch!(@db)
          Storage.process_attachment(blob.id) rescue nil
        else
          Storage.detach(@db, "Message", message.id, "attachment")
        end
      ensure
        upload.unlink if upload.respond_to?(:unlink)
      end
    end
  end
end
