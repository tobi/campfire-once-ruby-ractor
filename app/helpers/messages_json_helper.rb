# frozen_string_literal: true

module Campfire
  # The jbuilder views of the bot API: messages/_message.json, users/_user.json and
  # messages/boosts/_boost.json, written straight into a String with ActiveSupport's
  # JSON escaping (RailsCompat::Util.as_json_encode: <, > and & as \uXXXX; load_defaults
  # 8.2 leaves U+2028/9 alone).
  #
  # `json.cache! message` / `json.cache! boost` become per-Ractor fragments keyed by
  # the record's version and the request's base URL (the URLs inside are absolute).
  module Helpers
    JSON_USER = "SELECT id, name, role, updated_at FROM users WHERE id = ?"

    # `time.utc.as_json`: xmlschema(3), truncated to milliseconds.
    def json_time(db_time)
      out = String.new(capacity: 26)
      out << '"' << db_time.byteslice(0, 10) << "T" << db_time.byteslice(11, 8)
      frac = db_time.bytesize > 20 ? db_time.byteslice(20, 3) : nil
      out << "." << (frac.nil? || frac.empty? ? "000" : frac.ljust(3, "0")) << 'Z"'
    end

    def json_string(s) = RailsCompat::Util.as_json_encode(s.to_s)

    # users/_user.json (a nil user renders as [], jbuilder's nil partial object).
    def user_json(out, user_id)
      row = (@json_users ||= {}).fetch(user_id) { @json_users[user_id] = @db.query_single_array(JSON_USER.freeze, user_id) }
      return out << "[]" unless row
      id, name, role, updated_at = row
      out << '{"id":' << id.to_s << ',"name":' << json_string(name) << ',"role":"' << User::ROLES.fetch(role) <<
        '","avatar_url":' << json_string(base_url + fresh_user_avatar_path(id, updated_at)) << "}"
    end

    # messages/_message.json for a page (ids + versions), as a JSON array.
    def messages_json(page)
      out = String.new(capacity: 512 * (page.size + 1))
      out << "["
      missing = nil
      page.ids.each_with_index do |id, i|
        (missing ||= []) << id unless cached_json(:message_json, id, page.versions[i])
      end
      loaded = missing ? Message.load_presentation(@db, missing) : nil
      page.ids.each_with_index do |id, i|
        out << "," if i > 0
        out << (cached_json(:message_json, id, page.versions[i]) || message_json(loaded.fetch(id)))
      end
      out << "]"
    end

    # messages/_message.json for a fully loaded Message (load_one / load_presentation).
    def message_json(message)
      Cache.fragment(:message_json, message.id, [Message.version(message.updated_at), base_url]) do
        message.context!(host_without_port, user_resolver)
        out = String.new(capacity: 1024)
        out << '{"id":' << message.id.to_s << ',"created_at":' << json_time(message.created_at)
        out << ',"body":{"plain_text":' << json_string(message.plain_text_body)
        out << ',"html":' << json_string(message_body_html(message)) << '},"creator":'
        user_json(out, message.creator_id)
        out << ',"room":{"id":' << message.room_id.to_s << '},"url":'
        out << json_string("#{base_url}/rooms/#{message.room_id}/messages/#{message.id}") << "}"
      end
    end

    # messages/boosts/_boost.json
    def boost_json(boost, message, created_at)
      Cache.fragment(:boost_json, boost.id, [Message.version(boost.updated_at), base_url]) do
        out = String.new(capacity: 512)
        out << '{"id":' << boost.id.to_s << ',"content":' << json_string(boost.content)
        out << ',"created_at":' << json_time(created_at) << ',"booster":'
        user_json(out, boost.booster_id)
        out << ',"message":{"id":' << boost.message_id.to_s << ',"url":'
        out << json_string("#{base_url}/rooms/#{message.room_id}/messages/#{message.id}") << "}}"
      end
    end

    # message.body.to_s: the rich text rendered with its layout ("" without a body).
    def message_body_html(message)
      return "" unless message.body
      RichText.body_html(message.body, host: host_without_port, resolver: user_resolver)
    rescue RichText::Error
      ""
    end

    private

    def cached_json(name, id, version)
      entry = Cache.table(name)[id]
      entry[1] if entry && entry[0][0] == version && entry[0][1] == base_url
    end
  end
end
