# frozen_string_literal: true

module Campfire
  # Bits shared by the signed-out pages (sessions/new, users/new).
  module Helpers
    ADMINISTRATOR_SQL = "SELECT name, email_address FROM users WHERE role = 1 ORDER BY id LIMIT 1".freeze

    # render "accounts/help_contact" (User.administrator.first).
    def help_contact
      name, email = @db.query_single_splat(ADMINISTRATOR_SQL)
      return nil unless name || email
      @b << "  <div class=\"txt-align-center margin-block-double full-width\">\n    <a class=\"btn center\" title=\"Email "
      h(name)
      @b << "\" href=\""
      h("mailto:\"#{name}\" <#{email}>")
      @b << "\">\n      <img aria-hidden=\"true\" src=\"" << Assets.path("lifebuoy.svg") << "\" />\n      <span>"
      h(email)
      @b << "</span>\n</a>\n    <div class=\"txt-align-center center margin-block txt-subtle\">Campfire&trade; version "
      version_badge
      @b << "</div>\n  </div>\n"
      nil
    end

    # turbo_page_requires_reload
    TURBO_RELOAD_META = '<meta name="turbo-visit-control" content="reload">'
  end
end

module Campfire
  module Helpers
    # image_url: absolute asset URL.
    def image_url(logical) = base_url + Assets.path(logical)

    # fresh_account_logo_path(size: :small): url_for sorts the query keys,
    # so size comes before v.
    def manifest_small_logo_path
      a = account
      a&.updated_at ? "/account/logo?size=small&v=#{Clock.number(a.updated_at)}" : "/account/logo?size=small"
    end
  end
end

module Campfire
  module Helpers
    # user.attachable_sgid (deterministic; memoized per worker).
    def user_attachable_sgid(user_id)
      Cache.fetch(:user_attachable_sgid, user_id) { Campfire.secrets.attachable_sgid("User", user_id).freeze }
    end

    # autocompletable/users/index.json.jbuilder
    def autocompletable_users_json(users)
      out = +"["
      users.each_with_index do |u, i|
        out << "," if i > 0
        out << RailsCompat::Util.as_json_encode({
          "name" => ERB::Escape.html_escape(u.name), "value" => u.id,
          "avatar_url" => base_url + fresh_user_avatar_path(u.id, u.updated_at),
          "sgid" => user_attachable_sgid(u.id)
        })
      end
      out << "]"
    end
  end
end
