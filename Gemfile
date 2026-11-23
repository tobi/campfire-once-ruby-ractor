source "https://rubygems.org"
gem "falcon"
# Patched 3.1.3: Database#close no longer double-finalizes FTS5 statements.
gem "extralite", path: "vendor/gems/extralite"
gem "bcrypt"
gem "async-websocket"
gem "erb"
gem "json"
# CAMPFIRE_SERVER=kino: `bundle config set --local with kino`.
group :kino, optional: true do
  gem "kino", "~> 0.8"
end
