# frozen_string_literal: true

module Campfire
  # Ractor-local memo tables. Each worker Ractor has its own copy, so there is
  # no locking; entries are bounded by wholesale clearing when a table fills.
  module Cache
    LIMIT = 10_000

    module_function

    def table(name)
      Ractor[name] ||= {}
    end

    def fetch(name, key)
      t = table(name)
      t.fetch(key) do
        t.clear if t.size >= LIMIT
        t[key] = yield
      end
    end

    # Signed `session_token` cookie -> token (or false when invalid).
    def session_token(raw)
      v = fetch(:c_token, raw) { Campfire.secrets.verify_cookie(TOKEN, raw) || false }
      v || nil
    end

    # Fresh signed cookie value for a token, regenerated at most once a minute
    # (the payload embeds an expiry timestamp, as Rails' permanent cookies do).
    def signed_session_token(token)
      minute = Process.clock_gettime(Process::CLOCK_MONOTONIC, :second) / 60
      entry = table(:c_signed)[token]
      return entry[1] if entry && entry[0] == minute
      value = Campfire.secrets.sign_cookie(TOKEN, token, expires: Campfire.secrets.permanent_expiry)
      t = table(:c_signed)
      t.clear if t.size >= LIMIT
      t[token] = [minute, value]
      value
    end
    TOKEN = "session_token"

    # Encrypted Rails session cookie -> frozen Hash.
    def session(raw)
      fetch(:c_session, raw) do
        h = Campfire.secrets.decrypt_cookie(Controller::SESSION_COOKIE, raw)
        h.is_a?(Hash) ? h.freeze : {}.freeze
      end
    end

    # Rendered HTML fragments keyed by record id, validated by updated_at.
    def fragment(name, id, version)
      t = table(name)
      entry = t[id]
      return entry[1] if entry && entry[0] == version
      html = yield
      t.clear if t.size >= LIMIT
      t[id] = [version, html.freeze]
      html
    end

    def peek_fragment(name, id, version)
      entry = table(name)[id]
      entry[1] if entry && entry[0] == version
    end

    def invalidate(name, id = nil)
      id ? table(name).delete(id) : table(name).clear
    end
  end
end
