# frozen_string_literal: true

# Rails-compatible signing, encryption, cookie and CSRF primitives for the
# Campfire port, byte-compatible with Rails 8.2 (load_defaults 8.2) as the
# upstream app configures it. Pure Ruby over stdlib openssl/json (Base64 via
# pack/unpack). Every constant is deeply frozen and all state lives in the
# immutable Secrets object, so everything is usable from any Ractor.
#
#   SECRETS = Campfire::RailsCompat::Secrets.new(ENV.fetch("SECRET_KEY_BASE"))
#   # already Ractor.make_shareable'd; pass it to workers or keep it in a constant
#
#   raw   = Campfire::RailsCompat.cookie_value(env["HTTP_COOKIE"], "session_token")
#   token = SECRETS.verify_cookie("session_token", raw) if raw
#   sess  = SECRETS.decrypt_cookie("_campfire_session", RailsCompat.cookie_value(hdr, "_campfire_session"))
#
# Files:
#   rails_compat/util.rb              base64 / AS::JSON / iso8601 / compare helpers
#   rails_compat/message_verifier.rb  Metadata envelopes + MessageVerifier
#   rails_compat/message_encryptor.rb aes-256-gcm MessageEncryptor
#   rails_compat/cookies.rb           Rack cookie escaping, parsing, Set-Cookie
#   rails_compat/csrf.rb              authenticity tokens + origin check
#   rails_compat/global_id.rb         GID parsing, unverified attachable sgids
#   rails_compat/secrets.rb           everything keyed by SECRET_KEY_BASE

require_relative "rails_compat/util"
require_relative "rails_compat/message_verifier"
require_relative "rails_compat/message_encryptor"
require_relative "rails_compat/cookies"
require_relative "rails_compat/csrf"
require_relative "rails_compat/global_id"
require_relative "rails_compat/secrets"

module Campfire
  module RailsCompat
    # Cookie names and attributes the app uses (upstream):
    #   session_token      cookies.signed.permanent, httponly, samesite=lax, path=/
    #                      (expires 20 years; `secure` added under force_ssl)
    #   _campfire_session  Rails cookie session store, encrypted (aes-256-gcm),
    #                      expire_after 20.years, httponly, samesite=lax, path=/
    #   last_room          cookies.permanent (plain, unsigned), samesite=lax, path=/
    SESSION_TOKEN_COOKIE = "session_token"
    SESSION_COOKIE = "_campfire_session"
    LAST_ROOM_COOKIE = "last_room"

    module_function

    def escape_cookie(value) = Cookies.escape(value)
    def unescape_cookie(wire) = Cookies.unescape(wire)
    def cookie_value(header, name) = Cookies.cookie_value(header, name)
    def parse_cookie_header(header) = Cookies.parse_cookie_header(header)

    def set_cookie_header(name, value, **opts) = Cookies.set_cookie_header(name, value, **opts)
    def delete_cookie_header(name, **opts) = Cookies.delete_cookie_header(name, **opts)

    # Set-Cookie for `cookies.signed.permanent[:session_token] = { value:,
    # httponly: true, same_site: :lax }`.
    def session_token_set_cookie(secrets, token, now: Time.now, secure: false)
      expires = Util.years_from(now, 20)
      Cookies.set_cookie_header(SESSION_TOKEN_COOKIE, secrets.sign_cookie(SESSION_TOKEN_COOKIE, token, expires: expires),
        expires: expires, httponly: true, secure: secure)
    end

    # Set-Cookie for the Rails session (cookie_store, expire_after: 20.years).
    def session_set_cookie(secrets, session_hash, now: Time.now, secure: false)
      expires = Util.years_from(now, 20)
      Cookies.set_cookie_header(SESSION_COOKIE, secrets.encrypt_cookie(SESSION_COOKIE, session_hash, expires: expires),
        expires: expires, httponly: true, secure: secure)
    end

    # Set-Cookie for `cookies.permanent[:last_room] = room.id`.
    def last_room_set_cookie(room_id, now: Time.now, secure: false)
      Cookies.set_cookie_header(LAST_ROOM_COOKIE, room_id.to_s, expires: Util.years_from(now, 20), secure: secure)
    end

    # String#underscore for class names: "Rooms::Open" -> "rooms/open",
    # "HTTPRequest" -> "http_request".
    def underscore(name)
      return name.downcase if name.match?(/\A[A-Z][a-z0-9]*\z/) # fast path: "User"
      s = name.gsub("::", "/")
      s = s.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2')
      s = s.gsub(/([a-z\d])([A-Z])/, '\1_\2')
      s.tr!("-", "_")
      s.downcase!
      s
    end
  end
end
