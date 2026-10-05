# frozen_string_literal: true

require_relative "delivery"

module Campfire
  # Bot::WebhookJob + Webhook#deliver: Jobs.later(:webhook, bot_id, message_id).
  #
  # POSTs the message as JSON to the bot's webhook (7 s open/read timeouts, no
  # private-network guard: only administrators set the URL). A 200 text/html or
  # text/plain reply is posted to the room as the bot; any other reply with a
  # recognised Content-Type becomes an attachment message. A timeout posts
  # "Failed to respond within 7 seconds".
  module WebhookJob
    TIMEOUT = Webhook::ENDPOINT_TIMEOUT
    MAX_REPLY = 100 << 20
    TIMEOUT_TEXT = "Failed to respond within #{TIMEOUT} seconds"
    TIMEOUTS = [Async::TimeoutError, IO::TimeoutError, Errno::ETIMEDOUT].freeze

    # Mime::Type.lookup -> [symbol, registered type] (the reference app's registrations).
    MIME = {
      "text/html" => %w[html text/html], "application/xhtml+xml" => %w[html text/html],
      "text/plain" => %w[text text/plain],
      "text/javascript" => %w[js text/javascript], "application/javascript" => %w[js text/javascript],
      "application/x-javascript" => %w[js text/javascript],
      "text/css" => %w[css text/css], "text/calendar" => %w[ics text/calendar], "text/csv" => %w[csv text/csv],
      "text/vcard" => %w[vcf text/vcard], "text/vtt" => %w[vtt text/vtt], "vtt" => %w[vtt text/vtt],
      "text/markdown" => %w[md text/markdown],
      "image/png" => %w[png image/png], "image/jpeg" => %w[jpeg image/jpeg], "image/gif" => %w[gif image/gif],
      "image/bmp" => %w[bmp image/bmp], "image/tiff" => %w[tiff image/tiff], "image/svg+xml" => %w[svg image/svg+xml],
      "image/webp" => %w[webp image/webp],
      "video/mpeg" => %w[mpeg video/mpeg], "audio/mpeg" => %w[mp3 audio/mpeg], "audio/ogg" => %w[ogg audio/ogg],
      "audio/aac" => %w[m4a audio/aac], "audio/mp4" => %w[m4a audio/aac],
      "video/webm" => %w[webm video/webm], "video/mp4" => %w[mp4 video/mp4],
      "font/otf" => %w[otf font/otf], "font/ttf" => %w[ttf font/ttf], "font/woff" => %w[woff font/woff],
      "font/woff2" => %w[woff2 font/woff2],
      "application/xml" => %w[xml application/xml], "text/xml" => %w[xml application/xml],
      "application/x-xml" => %w[xml application/xml],
      "application/rss+xml" => %w[rss application/rss+xml], "application/atom+xml" => %w[atom application/atom+xml],
      "application/x-yaml" => %w[yaml application/x-yaml], "text/yaml" => %w[yaml application/x-yaml],
      "multipart/form-data" => %w[multipart_form multipart/form-data],
      "application/x-www-form-urlencoded" => %w[url_encoded_form application/x-www-form-urlencoded],
      "application/json" => %w[json application/json], "text/x-json" => %w[json application/json],
      "application/jsonrequest" => %w[json application/json], "application/problem+json" => %w[json application/json],
      "application/pdf" => %w[pdf application/pdf], "application/zip" => %w[zip application/zip],
      "application/gzip" => %w[gzip application/gzip], "application/x-gzip" => %w[gzip application/gzip],
      "text/vnd.turbo-stream.html" => %w[turbo_stream text/vnd.turbo-stream.html]
    }.freeze
    MIME_NAME = "[a-zA-Z0-9][a-zA-Z0-9!#$&\\-^_.+]{0,126}"
    MIME_PATTERN = %r{\A(?:\*/\*|#{MIME_NAME}/(?:\*|#{MIME_NAME}))\z}

    HEADERS = [["content-type", "application/json"], ["accept", "*/*"], ["user-agent", "Ruby"]].freeze
    BOT = "SELECT id, name, bot_token, bio, updated_at FROM users WHERE id = ? AND role = 2"
    RICH_TEXT = "SELECT body FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ? AND name = 'body' LIMIT 1"
    INSERT_MESSAGE = "INSERT INTO messages (client_message_id, created_at, updated_at, creator_id, room_id) VALUES (?, ?, ?, ?, ?)"

    Bot = Struct.new(:id, :name, :bot_token, :bio, :updated_at) do
      def bot_key = "#{id}-#{bot_token}"
    end

    module_function

    def perform(bot_id, message_id)
      db = DB.connection
      bot = db.query_single_array(BOT, bot_id) or return
      bot = Bot.new(*bot)
      webhook = Webhook.for_user(db, bot.id) or return
      message = Message.load_one(db, message_id) or return
      room = Room.find(db, message.room_id) or return
      reply = post(webhook.url, payload(db, bot, room, message))
      receive_reply(db, bot, room, reply) if reply
    end

    # Webhook#payload (ActiveSupport::JSON: <, >, & escaped).
    def payload(db, bot, room, message)
      Cable::Frames.json({
        user: { id: message.creator_id, name: message.creator_name },
        room: { id: room.id, name: room.name, path: "/rooms/#{room.id}/#{bot.bot_key}/messages" },
        message: {
          id: message.id,
          body: { html: db.query_single_splat(RICH_TEXT, message.id), plain: without_recipient_mentions(bot, Delivery.plain_text_body(db, message)) },
          path: "/rooms/#{room.id}/@#{message.id}"
        }
      })
    end

    def without_recipient_mentions(bot, body)
      body.gsub("@#{bot.name}", "").gsub(/\A\p{Space}+|\p{Space}+\z/, "")
    end

    # -> [:text, String] | [:attachment, data, filename, content_type] | nil
    def post(url, json)
      uri = URI.parse(url)
      raise ArgumentError, "invalid webhook URL" unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty?
      host = uri.host.delete_prefix("[").delete_suffix("]")
      response = Sync do |task|
        task.with_timeout(60) do
          ips = task.with_timeout(TIMEOUT) { Outbound.resolve(host, uri.port) }
          raise SocketError, "no address for #{host}" if ips.empty?
          # Like Net::HTTP (Socket.tcp), try each address until one connects.
          begin
            Outbound.post(uri, json, HEADERS, ip: ips.first, timeout: TIMEOUT, limit: MAX_REPLY)
          rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL
            ips.shift
            raise if ips.empty?
            retry
          end
        end
      end
      interpret(response)
    rescue *TIMEOUTS
      [:text, TIMEOUT_TEXT]
    end

    # Webhook#extract_text_from / #extract_attachment_from
    def interpret(response)
      return nil if response.content_type.nil?
      type = media_type(response.content_type)
      if response.status == 200 && (type == "text/plain" || type == "text/html")
        return [:text, response.body.dup.force_encoding(Encoding::UTF_8).scrub("�")]
      end
      symbol, registered = mime_lookup(type)
      return nil if registered.nil?
      [:attachment, response.body, "attachment.#{symbol}", registered]
    end

    def media_type(header)
      main, sub = header.split(";", 2).first.split("/", 3)
      strip = ->(s) { s.to_s.gsub(/\A[ \t\n\v\f\r\0]+|[ \t\n\v\f\r\0]+\z/, "") }
      sub.nil? ? strip.(main) : "#{strip.(main)}/#{strip.(sub)}"
    end

    def mime_lookup(type)
      MIME[type] || (MIME_PATTERN.match?(type) ? ["", type] : nil)
    end

    def receive_reply(db, bot, room, reply)
      message =
        case reply[0]
        when :text then Message.create!(db, room, bot, body: reply[1])
        when :attachment then create_with_attachment(db, room, bot, *reply[1..])
        end
      Delivery.receive(room, message)
      Delivery.broadcast_create(db, room, message)
      message
    end

    # room.messages.create_with_attachment!(attachment:, creator:)
    def create_with_attachment(db, room, bot, data, filename, content_type)
      now = Clock.now_db
      staged = Storage.stage_upload(filename, content_type, data)
      id = blob = nil
      db.transaction do
        db.execute(INSERT_MESSAGE, SecureRandom.uuid, now, now, bot.id, room.id)
        id = db.last_insert_rowid
        blob = staged.insert(db)
      end
      Storage.attach(db, blob.id, "Message", id, "attachment", analyze: false)
      Storage.process_attachment(blob.id) rescue nil
      message = Message.load_one(db, id)
      Message.index!(db, message)
      message
    ensure
      staged&.discard
    end
  end

  Jobs.register(:webhook, WebhookJob)
end
