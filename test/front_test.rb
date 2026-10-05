# frozen_string_literal: true

require "minitest/autorun"
require "zlib"
require_relative "support/app_harness"

AppHarness.boot!

# The front layer (lib/campfire/front.rb): Rails' response finishing, Rack::Deflater and
# Thruster's cache, driven through App#call the way Falcon calls it.
class FrontTest < Minitest::Test
  ROOM = "/rooms/486777696"
  CHROME_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
  GZIP = "gzip, deflate, br, zstd"
  DEFAULTS = %w[x-frame-options x-xss-protection x-content-type-options x-permitted-cross-domain-policies referrer-policy].freeze

  Reply = Struct.new(:status, :headers, :body) do
    def [](name) = headers.fetch(name, nil)&.join(", ")
    def all(name) = headers.fetch(name, [])
    def text = self["content-encoding"] == "gzip" && !body.empty? ? Zlib.gunzip(body) : body
  end

  def setup
    Ractor.current[:front_cache] = nil
  end

  def request(method, path, headers = {}, cookie = true)
    h = Protocol::HTTP::Headers.new
    h.add("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
    h.add("cookie", AppHarness.cookie_header) if cookie
    headers.each { |k, v| h.add(k, v) }
    req = Protocol::HTTP::Request.new("http", AppHarness::HOST, method, path, "HTTP/1.1", h, nil)
    res = AppHarness.app.call(req)
    fields = Hash.new { |hash, k| hash[k] = [] }
    res.headers.each { |k, v| fields[k] << v.to_s }
    body = res.body ? res.body.join.to_s : +""
    Reply.new(res.status, fields, body.b)
  end

  def get(path, headers = {}, cookie = true) = request("GET", path, { "accept-encoding" => GZIP }.merge(headers), cookie)

  def test_asset_is_served_like_action_dispatch_static_behind_thruster
    path = Campfire::Assets.path("application.js")
    file = Campfire::Assets.file(path)
    miss = get(path, "accept" => "*/*")
    assert_equal 200, miss.status
    assert_equal "text/javascript", miss["content-type"]
    assert_equal "public, max-age=2592000", miss["cache-control"]
    assert_equal file.last_modified, miss["last-modified"]
    assert_equal "gzip", miss["content-encoding"]
    assert_equal ["Accept-Encoding"], miss.all("vary")
    assert_equal "miss", miss["x-cache"]
    assert_nil miss["etag"]
    DEFAULTS.each { |name| assert_nil miss[name], name }
    assert_equal file.body.b, miss.text

    hit = get(path, "accept" => "*/*")
    assert_equal "hit", hit["x-cache"]
    assert_equal file.body.b, hit.text

    # Without Accept-Encoding the body goes out as is (a separate cache variant).
    plain = request("GET", path)
    assert_nil plain["content-encoding"]
    assert_equal "miss", plain["x-cache"]
    assert_equal file.body.b, plain.body
  end

  # <audio> fetches with Range (interactions/composer/play_sound). A duplicate Content-Length
  # here made the proxy answer 502.
  def test_asset_range_requests_like_rack_files
    path = "/assets/crickets-b50f1da0.mp3"
    size = Campfire::Assets.file(path).body.bytesize
    identity = { "accept-encoding" => "identity;q=1, *;q=0" }
    whole = request("GET", path, identity.merge("range" => "bytes=0-"))
    assert_equal 206, whole.status
    assert_equal "bytes 0-#{size - 1}/#{size}", whole["content-range"]
    assert_equal size, whole.body.bytesize
    assert_equal "bypass", whole["x-cache"]
    assert_empty whole.all("content-length")
    assert_equal ["Accept-Encoding", "Accept-Encoding"], whole.all("vary")

    part = request("GET", path, identity.merge("range" => "bytes=100-199"))
    assert_equal [206, "bytes 100-199/#{size}", 100], [part.status, part["content-range"], part.body.bytesize]
    tail = request("GET", path, identity.merge("range" => "bytes=-10"))
    assert_equal "bytes #{size - 10}-#{size - 1}/#{size}", tail["content-range"]

    bad = request("GET", path, identity.merge("range" => "bytes=99999999-"))
    assert_equal [416, "bytes */#{size}", "Byte range unsatisfiable\n"], [bad.status, bad["content-range"], bad.body]
    assert_equal 200, request("GET", path, identity.merge("range" => "bytes=0-1,5-6")).status
  end

  def test_asset_if_modified_since_is_a_bare_304_on_a_miss
    path = Campfire::Assets.path("application.js")
    reply = get(path, "if-modified-since" => Campfire::Assets.file(path).last_modified)
    assert_equal 304, reply.status
    assert_equal %w[vary x-cache], reply.headers.keys.sort
    assert_empty reply.body
  end

  def test_html_page_gets_rails_headers_etag_and_gzip
    reply = get(ROOM, "accept" => CHROME_ACCEPT)
    assert_equal 200, reply.status
    assert_equal "text/html; charset=utf-8", reply["content-type"]
    assert_equal "max-age=0, private, must-revalidate", reply["cache-control"]
    assert_match %r{\AW/"\h{32}"\z}, reply["etag"]
    assert_equal "gzip", reply["content-encoding"]
    assert_equal ["Accept-Encoding"], reply.all("vary"), "browser Accept: no Vary: Accept"
    assert_equal "miss", reply["x-cache"]
    assert_match(/rel=preload; as=style; nopush/, reply["link"])
    DEFAULTS.each { |name| refute_nil reply[name], name }
    refute_nil reply["x-version"]
    assert_includes reply.text, "<html"
    # A page of cached messages is digested and gzipped in parts (test/page_parts_test.rb).
    assert_equal reply.text.bytesize, Zlib.gunzip(reply.body).bytesize

    # An API-style Accept varies on Accept; Rack::Deflater appends Accept-Encoding.
    assert_equal ["Accept,Accept-Encoding"], get(ROOM, "accept" => "*/*").all("vary")
  end

  # (Pages carrying a CSRF token never match: the masked token changes per request.)
  def test_rendered_response_with_matching_etag_is_a_304
    etag = get("/webmanifest.json", "accept" => "*/*")["etag"]
    reply = get("/webmanifest.json", "accept" => "*/*", "if-none-match" => etag)
    assert_equal 304, reply.status
    assert_nil reply["content-type"]
    assert_nil reply["content-encoding"]
    assert_equal etag, reply["etag"]
    assert_equal "miss", reply["x-cache"]
    assert_empty reply.body
  end

  def test_turbo_stream
    reply = get("#{ROOM}/refresh?since=1&reason=connection", "accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml")
    assert_equal 200, reply.status
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", reply["content-type"]
    assert_equal ["Accept,Accept-Encoding"], reply.all("vary")
    assert_equal "gzip", reply["content-encoding"]
    refute_nil reply["etag"]
    assert_nil reply["link"], "no layout, no preload header"
  end

  def test_redirect_is_gzipped_with_no_cache
    reply = get(ROOM, { "accept" => CHROME_ACCEPT }, false)
    assert_equal 302, reply.status
    assert_match %r{/session/new\z}, reply["location"]
    assert_equal "text/html; charset=utf-8", reply["content-type"]
    assert_equal "no-cache", reply["cache-control"]
    assert_equal "gzip", reply["content-encoding"]
    assert_equal "miss", reply["x-cache"]
    assert_nil reply["etag"]
  end

  def test_cacheable_avatar_misses_then_hits_without_cookies
    path = avatar_path
    miss = get(path, "accept" => "image/avif,image/webp,*/*")
    assert_equal 200, miss.status
    assert_equal "miss", miss["x-cache"]
    assert_equal "max-age=1800, public, stale-while-revalidate=604800", miss["cache-control"]
    assert_empty miss.all("set-cookie"), "Thruster strips cookies from cacheable responses"
    DEFAULTS.each { |name| assert_nil miss[name], "Live responses skip #{name}" }
    refute_nil miss["etag"]

    hit = get(path, "accept" => "image/avif,image/webp,*/*")
    assert_equal 200, hit.status
    assert_equal "hit", hit["x-cache"]
    assert_equal miss.text, hit.text
    assert_equal miss["etag"], hit["etag"]

    cached_304 = get(path, "if-none-match" => miss["etag"])
    assert_equal [304, "hit"], [cached_304.status, cached_304["x-cache"]]
    assert_nil cached_304["content-type"]
    assert_empty cached_304.body
  end

  def test_live_avatar_304_from_the_app_says_no_cache
    path = avatar_path
    etag = request("GET", path)["etag"]
    Ractor.current[:front_cache] = nil
    reply = get(path, "if-none-match" => etag)
    assert_equal [304, "miss"], [reply.status, reply["x-cache"]]
    assert_equal "no-cache", reply["cache-control"]
    DEFAULTS.each { |name| assert_nil reply[name], name }
  end

  def test_head_keeps_get_headers_without_a_body
    get_reply = get(ROOM, "accept" => CHROME_ACCEPT)
    head = request("HEAD", ROOM, "accept" => CHROME_ACCEPT, "accept-encoding" => GZIP)
    assert_equal 200, head.status
    assert_empty head.body
    assert_equal get_reply.headers.keys.sort, head.headers.keys.sort
    assert_equal "gzip", head["content-encoding"]

    asset = request("HEAD", Campfire::Assets.path("application.js"), "accept-encoding" => GZIP)
    assert_equal [200, "gzip", "miss"], [asset.status, asset["content-encoding"], asset["x-cache"]]
    assert_empty asset.body
  end

  def test_non_get_requests_bypass_the_cache
    reply = request("POST", "/nope", "accept-encoding" => GZIP)
    assert_equal 404, reply.status
    assert_equal "bypass", reply["x-cache"]
    assert_equal "text/html; charset=UTF-8", reply["content-type"]
    assert_equal %w[Accept-Encoding Accept-Encoding], reply.all("vary")
    DEFAULTS.each { |name| assert_nil reply[name], name }
  end

  def test_cache_is_bounded_and_expires
    cache = Campfire::Front::Cache.new(100)
    entry = ->(bytes, expires) { Campfire::Front::Entry.new(200, [], "x" * bytes, nil, expires, bytes) }
    cache.set("a", entry.(40, 10))
    cache.set("b", entry.(40, 10))
    refute_nil cache.get("a", 1) # a is now the most recent
    cache.set("c", entry.(40, 10))
    assert_nil cache.get("b", 1), "least recently used goes first"
    refute_nil cache.get("a", 1)
    assert_nil cache.get("c", 11), "expired"
  end

  private

  def avatar_path
    "/users/#{Campfire::Helpers.avatar_token(AppHarness::DAVID)}/avatar?v=1"
  end
end
