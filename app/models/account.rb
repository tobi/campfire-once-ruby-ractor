# frozen_string_literal: true

require_relative "models"

module Campfire
  # Account writes (upstream Account + Account::Joinable). The struct and reads
  # live in models.rb; this file loads it first so it can reopen the class.
  class Account
    SETTINGS_KEY = "restrict_room_creation_to_administrators"
    FALSE_VALUES = ["0", "f", "F", "false", "FALSE", "off", "OFF", ""].freeze

    # ActiveRecord update!: writes only changed columns and bumps updated_at
    # only when something changed. `attrs` keys: "name", "custom_styles",
    # "settings" (Hash). Returns true when a row was written.
    def update!(db, attrs, now: Clock.now_db)
      sets = nil
      binds = nil
      if attrs.key?("name") && attrs["name"].to_s != name
        (sets ||= []) << "name = ?"
        (binds ||= []) << (self.name = attrs["name"].to_s)
      end
      if attrs.key?("custom_styles") && attrs["custom_styles"] != custom_styles
        (sets ||= []) << "custom_styles = ?"
        (binds ||= []) << (self.custom_styles = attrs["custom_styles"])
      end
      if (s = attrs["settings"]).is_a?(Hash) && s.key?(SETTINGS_KEY)
        current = settings.dup
        current[SETTINGS_KEY] = !FALSE_VALUES.include?(s[SETTINGS_KEY].to_s)
        json = JSON.generate(current)
        if json != settings_json
          (sets ||= []) << "settings = ?"
          (binds ||= []) << (self.settings_json = json)
          @settings = current
        end
      end
      return false unless sets
      touch!(db, sets, binds, now)
      true
    end

    def reset_join_code!(db, now: Clock.now_db)
      self.join_code = Account.generate_join_code
      touch!(db, ["join_code = ?"], [join_code], now)
    end

    # Attaching or removing the logo touches the account (it's the logo ETag
    # and the ?v= cache buster).
    def touch_only!(db, now: Clock.now_db) = touch!(db, [], [], now)

    private

    def touch!(db, sets, binds, now)
      sets << "updated_at = ?"
      binds << now
      db.execute("UPDATE accounts SET #{sets.join(", ")} WHERE id = ?", *binds, id)
      self.updated_at = now
    end
  end
end
