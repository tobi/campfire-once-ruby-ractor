# frozen_string_literal: true

require "digest"

module Campfire
  # stale?(etag: record) + expires_in for the logo and avatar endpoints.
  # Rails' weak ETag is the SHA256 (first 32 hex chars) of the expanded cache
  # key "table/id-<updated_at %Y%m%d%H%M%S%6N>", plus the template digest when
  # the action has a template (users/avatars/show.svg.erb).
  module ConditionalGet
    AVATAR_TEMPLATE_DIGEST = "d500db55e2a67222018ef0156839c3c9"

    module_function

    def cache_version(updated_at)
      updated_at.byteslice(0, 4) + updated_at.byteslice(5, 2) + updated_at.byteslice(8, 2) +
        updated_at.byteslice(11, 2) + updated_at.byteslice(14, 2) + updated_at.byteslice(17, 2) +
        (updated_at.byteslice(20, 6) || "").ljust(6, "0")
    end

    def etag(table, id, updated_at, digest = nil)
      key = +"#{table}/#{id}-#{cache_version(updated_at)}"
      key << "/" << digest if digest
      %(W/"#{Digest::SHA256.hexdigest(key)[0, 32]}")
    end

    def fresh?(if_none_match, etag)
      return false if if_none_match.nil?
      if_none_match.to_s.split(",").any? { |t| (t = t.strip) == etag || t == "*" }
    end

    def content_disposition(filename) = Storage.content_disposition("inline", filename)
  end
end
