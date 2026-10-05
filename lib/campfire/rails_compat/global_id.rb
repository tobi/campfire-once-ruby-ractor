# frozen_string_literal: true

require_relative "util"

module Campfire
  module RailsCompat
    # GlobalID (`gid://campfire/User/1`) parsing/formatting, plus the
    # signature-ignoring attachable lookup of upstream's
    # lib/rails_ext/action_text_attachables.rb.
    #
    # `params` is the raw query string (Rails puts `?expires_in` into attachable
    # SGIDs) or nil; the locator ignores it.
    GID = Data.define(:app, :model_name, :id, :params) do
      def self.build(model_name, id, app: GlobalID::APP) = new(app, model_name.to_s, id.to_s, nil)

      def to_s
        s = "gid://#{app}/#{model_name}/#{id}"
        params ? "#{s}?#{params}" : s
      end

      # GlobalID#to_param: url-safe base64 without padding (Turbo stream names).
      def to_param = Util.urlsafe_encode64_unpadded(to_s)

      # Same record (app/model/id), ignoring params.
      def same_record?(other) = other.is_a?(GID) && app == other.app && model_name == other.model_name && id == other.id
    end

    module GlobalID
      APP = "campfire"                   # GlobalID.app (Campfire::Application)
      ATTACHABLE_PURPOSE = "attachable"  # ActionText::Attachable::LOCATOR_NAME
      DEFAULT_PURPOSE = "default"        # SignedGlobalID::DEFAULT_PURPOSE
      # lib/rails_ext/action_text_attachables.rb
      ATTACHABLES_PERMITTED_WITH_INVALID_SIGNATURES = ["User"].freeze
      MARSHAL_GID_RE = %r{(gid://campfire/[^/]+/\d+)}n
      HOST_RE = /\A[A-Za-z0-9\-.]+\z/

      module_function

      # GlobalID.parse: a URI ("gid://app/Model/id[?params]") or its base64
      # param form. nil if neither.
      def parse(gid)
        return gid if gid.is_a?(GID)
        return nil unless gid.is_a?(String)
        parse_uri(gid) || ((decoded = Util.urlsafe_decode64(gid)) && parse_uri(decoded.force_encoding(Encoding::UTF_8)))
      end

      def parse_uri(str)
        return nil unless str.start_with?("gid://") && str.valid_encoding?
        rest = str.byteslice(6, str.bytesize - 6)
        rest, params = rest.split("?", 2)
        return nil unless rest
        app, model_name, id = rest.split("/", 3)
        return nil if app.nil? || model_name.nil? || id.nil? || app.empty? || model_name.empty? || id.empty?
        return nil unless HOST_RE.match?(app)
        GID.new(app, model_name, id, params)
      end

      def from_param(param) = parse(param)

      # ActionText::Attachment.attachable_from_possibly_expired_sgid, minus the
      # database: the GID of the User the (possibly unsigned/expired/forged)
      # sgid names, or nil. The caller must still look the user up (missing ->
      # nil). Where Rails raises (malformed JSON/base64) this returns nil.
      def attachable_gid_from_possibly_expired_sgid(sgid)
        return nil unless sgid.is_a?(String)
        message = sgid.split("--").first or return nil
        json = Util.urlsafe_decode64(message) or return nil
        envelope = Util.as_json_decode(json.force_encoding(Encoding::UTF_8))
        return nil unless envelope.is_a?(Hash)
        rails = envelope["_rails"]
        return nil unless rails.is_a?(Hash)
        decoded =
          if (data = rails["data"])
            data
          elsif (data = rails["message"])
            raw = data.is_a?(String) && Util.urlsafe_decode64(data)
            raw && (m = MARSHAL_GID_RE.match(raw)) ? m[1].force_encoding(Encoding::UTF_8) : nil
          end
        gid = parse(decoded) or return nil
        ATTACHABLES_PERMITTED_WITH_INVALID_SIGNATURES.include?(gid.model_name) ? gid : nil
      rescue JSON::ParserError, EncodingError, TypeError
        nil
      end
    end
  end
end
