require "bundler/setup"
require "falcon"
require "async/websocket/adapters/http"
require "sqlite3"; require "bcrypt"; require "openssl"; require "json"; require "erb/escape"; require "nokogiri"
require_relative "../lib/ractor_compat"
RactorCompat.share_constants!
Ractor.make_shareable(BCrypt::Engine) rescue nil

tests = {
  sqlite: nil.instance_eval { -> { db = SQLite3::Database.new(":memory:"); db.execute("create virtual table f using fts5(body, tokenize=porter)"); db.execute("insert into f values ('hello coffee')"); db.execute("select * from f where f match 'coffee'").inspect } },
  bcrypt: nil.instance_eval { -> { BCrypt::Password.create("secret", cost: 4).is_password?("secret") } },
  openssl: nil.instance_eval { -> { k = OpenSSL::PKCS5.pbkdf2_hmac("s", "salt", 1000, 32, "SHA256"); c = OpenSSL::Cipher.new("aes-256-gcm").encrypt; c.key = k; c.iv = "0"*12; (c.update("hi") + c.final).bytesize } },
  json: nil.instance_eval { -> { JSON.generate(JSON.parse('{"a":[1,2]}')) } },
  erb: nil.instance_eval { -> { ERB::Escape.html_escape("<a>") } },
  nokogiri: nil.instance_eval { -> { Nokogiri::HTML5.fragment("<p>hi <b>x</b></p>").to_html } },
  nokogiri4: nil.instance_eval { -> { Nokogiri::HTML4::DocumentFragment.parse("<p>hi <b>x</b></p>").to_html } },
}
tests.each do |name, blk|
  r = Ractor.new(Ractor.make_shareable(blk)) { |b| begin; b.call; rescue Exception => e; "ERR #{e.class}: #{e.message[0,300]}"; end }
  puts "#{name}: #{r.value.inspect}"
end
