# frozen_string_literal: true

require "zlib"

module Campfire
  # Users::AvatarsHelper. Avatar URLs embed a signed id (an HMAC), memoized
  # per worker by user id.
  module Helpers
    AVATAR_COLORS = %w[
      #AF2E1B #CC6324 #3B4B59 #BFA07A #ED8008 #ED3F1C #BF1B1B #736B1E #D07B53
      #736356 #AD1D1D #BF7C2A #C09C6F #698F9C #7C956B #5D618F #3B3633 #67695E
    ].freeze

    def avatar_background_color(user_id)
      AVATAR_COLORS[Zlib.crc32(user_id.to_s) % AVATAR_COLORS.size]
    end

    # "/users/<signed id>/avatar?v=<updated_at number>" (fresh_user_avatar_path)
    def fresh_user_avatar_path(user_id, updated_at)
      t = Cache.table(:avatar_path)
      e = t[user_id]
      return e[1] if e && e[0] == updated_at
      s = (+"/users/" << Helpers.avatar_token(user_id) << "/avatar?v=" << Clock.number(updated_at)).freeze
      t.clear if t.size >= Cache::LIMIT
      t[user_id] = [updated_at, s].freeze
      s
    end

    def self.avatar_token(user_id)
      Cache.fetch(:avatar_token, user_id) { Campfire.secrets.signed_id("User", user_id, purpose: "avatar").freeze }
    end

    # avatar_tag(user): link to the profile wrapping the 48px avatar image.
    # `label` replaces aria-hidden with aria-label (boosts).
    def avatar_tag(user_id, name, bio, updated_at, label: nil)
      @b << '<a title="'
      user_title(name, bio)
      @b << '" class="btn avatar" data-turbo-frame="_top" href="/users/' << user_id.to_s << '"><img '
      if label
        @b << 'aria-label="'
        h(label)
        @b << '"'
      else
        @b << 'aria-hidden="true"'
      end
      @b << ' src="' << fresh_user_avatar_path(user_id, updated_at) << '" width="48" height="48" /></a>'
      nil
    end

    def current_user_avatar_tag
      u = current_user
      avatar_tag(u.id, u.name, u.bio, u.updated_at)
    end

    # User#title, escaped: "name – bio" (bio when present)
    def user_title(name, bio)
      h(name)
      if bio && !bio.strip.empty?
        @b << " – "
        h(bio)
      end
      nil
    end
  end
end
