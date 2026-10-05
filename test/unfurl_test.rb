# frozen_string_literal: true

# Link unfurling: PrivateNetworkGuard, the Opengraph scanner/sanitizing, the
# reference oracle replay (test/fixtures/opengraph_{cases,expected}.json, recorded
# against the Rails app by ref-rust's testdata/oracle/opengraph.rb: the response,
# the DNS lookups and the HTTP requests per case) and UnfurlLinksController.
#
# No internet: PrivateNetworkGuard.lookup is a fake resolver and Outbound's
# pinned connection to a fake public address goes to a local server.
require "minitest/autorun"
require "json"
require "zlib"
require "socket"
require_relative "support/app_harness"

AppHarness.boot!

# The oracle's fake server: routes by method, Host (port dropped, "*" for any)
# and target; optional gzip and chunked bodies.
class OracleServer
  Route = Struct.new(:method, :host, :path, :status, :headers, :body, :chunked, :gzip, :delay)
  Received = Struct.new(:method, :target, :headers)

  attr_reader :port, :received

  def initialize(routes)
    @routes = routes
    @received = []
    @lock = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      loop do
        sock = @server.accept
        Thread.new(sock) { |s| serve(s) }
      rescue IOError, Errno::EBADF
        break
      end
    end
  end

  def self.route(spec)
    body = if spec["body_b64"] then spec["body_b64"].unpack1("m")
    elsif spec["body_repeat"] then spec["body_repeat"][0] * spec["body_repeat"][1]
    else (spec["body"] || "").b
    end
    body = body.b.ljust(spec["pad_to"], " ") if spec["pad_to"]
    Route.new(spec["method"], spec["host"], spec["path"], spec["status"], spec["headers"] || [], body.b, spec["chunked"], spec["gzip"], 0)
  end

  def received_since(n) = @lock.synchronize { @received[n..] }
  def count = @lock.synchronize { @received.size }

  def serve(sock)
    line = sock.gets or return
    method, target, = line.split(" ")
    headers = []
    while (h = sock.gets) && h != "\r\n"
      name, value = h.chomp.split(": ", 2)
      headers << [name.downcase, value]
    end
    @lock.synchronize { @received << Received.new(method, target, headers.to_h) }
    host = headers.to_h["host"].to_s.sub(/:\d+\z/, "")
    route = @routes.find { |r| r.method == method && (r.host == host || r.host == "*") && r.path == target } ||
      Route.new(method, host, target, 404, [["Content-Type", "text/plain"]], "not found".b, false, false, 0)
    sleep(route.delay) if route.delay.positive?
    body = route.body
    body = Zlib.gzip(body) if route.gzip
    head = +"HTTP/1.1 #{route.status} X\r\n"
    route.headers.each { |k, v| head << "#{k}: #{v}\r\n" }
    head << "Content-Encoding: gzip\r\n" if route.gzip
    if route.chunked
      head << "Transfer-Encoding: chunked\r\n"
    elsif route.headers.none? { |k, _| k.casecmp?("content-length") }
      head << "Content-Length: #{body.bytesize}\r\n"
    end
    head << "Connection: close\r\n\r\n"
    sock.write(head)
    if method != "HEAD"
      if route.chunked
        (0...body.bytesize).step(64 * 1024) do |i|
          chunk = body.byteslice(i, 64 * 1024)
          sock.write("#{chunk.bytesize.to_s(16)}\r\n", chunk, "\r\n")
        end
        sock.write("0\r\n\r\n")
      else
        sock.write(body)
      end
    end
  rescue IOError, SystemCallError
    nil
  ensure
    sock.close rescue nil
  end

  def close
    @server.close rescue nil
    @thread.join(1)
  end
end

# Fake DNS (successive answers per host, the last one repeating) and a dialer
# sending the fake public addresses to a local server.
module FakeNet
  module_function

  def install!(hosts, public_ips, port)
    @hosts = hosts.transform_values { |lists| lists.map { |l| l.dup } }
    @lookups = []
    @dialed = []
    lookups = @lookups
    table = @hosts
    Campfire::PrivateNetworkGuard.define_singleton_method(:lookup) do |host|
      lookups << host
      lists = table[host] or raise SocketError, "no address for #{host}"
      (lists.size > 1 ? lists.shift : lists.first).map { |ip| IPAddr.new(ip) }
    end
    dialed = @dialed
    Campfire::Outbound.define_singleton_method(:tcp_endpoint) do |ip, p, timeout|
      dialed << [ip, p]
      public_ips.include?(ip) ? IO::Endpoint.tcp("127.0.0.1", port, timeout: timeout) : IO::Endpoint.tcp(ip, p, timeout: timeout)
    end
  end

  def lookups = @lookups
  def dialed = @dialed
end

class PrivateNetworkGuardTest < Minitest::Test
  G = Campfire::PrivateNetworkGuard

  BLOCKED = %w[0.0.0.0 10.1.2.3 100.64.0.1 127.0.0.1 168.63.129.16 169.254.169.254 172.16.0.0 172.31.255.255
    192.0.0.8 192.0.2.1 192.88.99.1 192.168.1.1 198.18.0.1 198.51.100.1 203.0.113.1 224.0.0.1 240.0.0.1
    255.255.255.255 :: ::1 ::ffff:192.168.1.1 ::ffff:8.8.8.8 ::8.8.8.8 64:ff9b::a00:1 64:ff9b:1::1
    ::ffff:0:a00:1 fc00::1 fd00::1 fe80::1 fec0::1 ff02::1 2001::1 2001:db8::1 2002::1 3fff::1
    5f00::1 100::1 2001:2::1 4000::1 2001:10::1].freeze
  PUBLIC = %w[8.8.8.8 1.1.1.1 93.184.216.34 142.250.185.206 172.32.0.1 100.128.0.1 192.0.1.1
    2606:2800:220:1:248:1893:25c8:1946 2a00:1450:4001:82a::200e 2001:3::1 2001:4:112::1 64:ff9b::808:808
    ::ffff:0:808:808 2c0f:ffff::1].freeze

  def test_classifies_addresses_like_surfguard
    BLOCKED.each { |ip| assert G.blocked_address?(ip), "#{ip} should be blocked" }
    PUBLIC.each { |ip| refute G.blocked_address?(ip), "#{ip} should be public" }
  end

  def test_inet_aton_forms
    { "127.1" => "127.0.0.1", "0x7f.1" => "127.0.0.1", "2130706433" => "127.0.0.1", "0177.0.0.01" => "127.0.0.1",
      "10.0.258" => "10.0.1.2" }.each { |host, ip| assert_equal ip, G.getaddrinfo_numeric(host).to_s, host }
    %w[09.1.1.1 256.1.1.1 www.example.com].each { |host| assert_nil G.getaddrinfo_numeric(host), host }
  end

  def test_resolves_hosts_like_the_private_network_guard
    FakeNet.install!({ "www.example.com" => [["93.184.216.34"]],
      "mixed.example" => [["10.0.0.1", "2606:2800:220:1:248:1893:25c8:1946", "::1", "93.184.216.39"]],
      "private.example" => [["192.168.1.10"]] }, [], 1)
    assert_equal "93.184.216.34", G.resolve("www.example.com")
    assert_equal ["93.184.216.39", "2606:2800:220:1:248:1893:25c8:1946"], G.resolve_public_ips("mixed.example")
    assert_nil G.resolve("private.example")
    assert_nil G.resolve("nowhere.example")
    assert_equal "8.8.8.8", G.resolve("8.8.8.8")
    assert_equal "2606:2800:220:1:248:1893:25c8:1946", G.resolve("[2606:2800:220:1:248:1893:25c8:1946]")
    ["127.0.0.1", "0x7f.1", "2130706433", "[::1]", "::1", "[fd00::1]", "under_score.example", "", "a..b", "1.2.3.4.",
      "01.2.3.4.", "host%eth0", "exämple.com", "-lead.example", "[v1.x]", nil].each { |host| assert_nil G.resolve(host), host.inspect }
    assert_equal %w[www.example.com mixed.example private.example nowhere.example], FakeNet.lookups
  end
end

class OpengraphDocumentTest < Minitest::Test
  D = Campfire::Opengraph::Document
  M = Campfire::Opengraph::Metadata

  def title(html)
    D.meta_elements(D.decode("<meta charset=utf-8>#{html}".b)).reverse.find { |m| m["property"] == "og:title" }&.then { |m| c = m["content"]; c.nil? || c.empty? ? nil : c }
  end

  def title_of(content) = title(%(<meta property="og:title" content="a#{content}b">))

  def test_decodes_references_like_libxml2
    { "&apos;" => "a'b", "&eacute" => "a&eacuteb", "&eacute;x" => "aéxb", "&#233" => "aéb", "&#233x" => "aéxb",
      "&#xE9" => "aປ", "&#xe9;" => "aéb", "&AMP;" => "a&AMP;b", "&Eacute;" => "aÉb", "&unknown;" => "a&unknown;b",
      "& x" => "a& xb", "&#65;&#x41;" => "aAAb", "&#128;" => "a\u0080b", "&#150;" => "a\u0096b", "&#xD800;" => "a",
      "&#1114112;" => "a", "&lt" => "a&ltb", "&amp;amp;" => "a&amp;b", "&hellip;" => "a…b", "&nbsp" => "a&nbspb",
      "&#;" => "a", "&#x;" => "a" }.each { |ref, expected| assert_equal expected, title_of(ref), ref }
  end

  def test_tokenizes_like_libxml2
    [
      [%(<script><meta property="og:title" content="in script"></script><meta property="og:title" content="after">), "after"],
      [%(<style><meta property="og:title" content="in style"></style>), nil],
      [%(<textarea><meta property="og:title" content="in textarea"></textarea>), "in textarea"],
      [%(<title><meta property="og:title" content="in title"></title>), "in title"],
      [%(<noscript><meta property="og:title" content="in noscript"></noscript>), "in noscript"],
      [%(<template><meta property="og:title" content="in template"></template>), "in template"],
      [%(<svg><meta property="og:title" content="in svg"></svg>), "in svg"],
      [%(<!-- <meta property="og:title" content="comment"> --><p>), nil],
      [%(<meta property=og:title content=unquoted>), "unquoted"],
      [%(<meta property="og:title" content="line1\r\nline2">), "line1\r\nline2"],
      [%(<meta property='og:title' content='single'>), "single"],
      [%(<meta property = "og:title" content = "spaced">), "spaced"],
      [%(<META PROPERTY="og:title" CONTENT="upper">), "upper"],
      [%(<meta property="og:title"content="nospace">), "nospace"],
      [%(<meta/property="og:title"/content="slashes">), nil],
      [%(<meta property="og:title" content="<b>tag</b>">), "<b>tag</b>"],
      [%(<meta property="og:title" content="a">b">), "a"],
      [%(<meta property="og:title" content="unterminated>), "unterminated>"],
      [%(<meta property="og:title" content=unq"uoted>), "unq\"uoted"],
      [%(<meta property="og:title" content=a&amp;b>), "a&b"],
      [%(<!--> <meta property="og:title" content="after empty comment"> -->), "after empty comment"],
      [%(<!---> <meta property="og:title" content="after dash comment"> -->), "after dash comment"],
      [%(<!DOCTYPE html><meta property="og:title" content="doctype">), "doctype"],
      [%(<?xml version="1.0"?><meta property="og:title" content="pi">), "pi"],
      [%(<![CDATA[ <meta property="og:title" content="cdata"> ]]>), nil],
      [%(<p <meta property="og:title" content="broken">), nil],
      [%(< meta property="og:title" content="space">), nil],
      [%(<meta property="og:title" content="tab\there">), "tab\there"],
      [%(<meta property="og:title" content="\x00nul">), nil]
    ].each { |html, expected| expected ? assert_equal(expected, title(html), html) : assert_nil(title(html), html) }
  end

  def test_decodes_bytes_like_libxml2_reading_utf8
    assert_equal "café ÿ x", D.decode("caf\xc3\xa9 \xff x".b)
    assert_equal "ÿ café x", D.decode("\xff caf\xc3\xa9 x".b)
    assert_equal "\u0093q\u0094", D.decode("\x93q\x94".b)
    assert_equal "\u0082 ", D.decode("\x82\xa0".b)
  end

  def test_finds_the_meta_encoding_like_nokogiri
    enc = ->(html) { D.meta_encoding(D.meta_elements(html)) }
    assert_equal "iso-8859-1", enc.(%(<meta charset="iso-8859-1">))
    assert_equal "", enc.(%(<meta charset="">))
    assert_equal "iso-8859-1", enc.(%(<meta http-equiv="content-type" content="text/html; charset=iso-8859-1">))
    assert_nil enc.(%(<meta http-equiv="Content-Type" content="text/html"><meta http-equiv="Content-Type" content="charset=utf-8">))
    assert_nil enc.(%(<meta http-equiv="refresh" content="charset=utf-8">))
    assert_nil enc.(%(<meta property="og:title" content="x">))
  end

  # test/models/opengraph/document_test.rb
  def test_extracts_opengraph_tags
    expected = { "title" => "Hey!", "url" => "https://example.com", "image" => "https://example.com/image.png", "description" => "desc.." }
    html = %(<html><head><meta property="og:url" content="https://example.com"><meta property="og:title" content="Hey!"><meta property="og:description" content="desc.."><meta property="og:image" content="https://example.com/image.png"></head></html>)
    assert_equal expected, D.opengraph_attributes(html.b)
    assert_equal expected.to_a, D.opengraph_attributes(html.b).to_a
    assert_equal expected, D.opengraph_attributes(html.gsub("property=", "name=").b)
    html = %(<html><head><meta name="og:url" content="https://example.com"><meta name="og:title" content="Hey!"><meta name="og:description" content="Hello â\u0080\u0099World"><meta name="og:image" content="https://example.com/image.png"></head></html>)
    assert_equal "Hello World", D.opengraph_attributes(html.b)["description"]
    assert_equal({}, D.opengraph_attributes(nil))
  end

  # Pages as large as a fetch allows, built to make a parser do quadratic work.
  def test_parses_pathological_pages_in_linear_time
    limit = Campfire::Opengraph::Fetch::MAX_BODY_SIZE
    fill = lambda do |open, item, close|
      page = +open
      i = 0
      while page.bytesize <= limit - close.bytesize - 64
        page << item.(i)
        i += 1
      end
      page << close
    end
    [
      fill.(%(<meta property="og:title" content="x" ), ->(i) { format("a%07d ", i) }, ">"),
      fill.("<meta charset=utf-8>", ->(i) { %(<meta property="og:t#{i}" content="x">) }, %(<meta property="og:title" content="x">)),
      fill.(%(<meta property="og:title" content="), ->(_) { "&amp;é" }, %(">))
    ].each do |page|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      found = D.opengraph_attributes(page.b)
      assert_equal "title", found.keys.first
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert elapsed < 5, "#{elapsed}s for #{page[0, 60]}"
    end
  end

  # Probed against the reference (strip_tags then sanitize).
  def test_strips_tags_like_rails
    { "Tom & Jerry" => "Tom &amp; Jerry", "a < b" => "a &lt; b", "x&nbsp;y" => "x&nbsp;y", " nb" => "&nbsp;nb",
      "Hey!<script>alert('hi')</script>" => "Hey!alert('hi')", "<!-- c -->t" => "t", "a &lt;b&gt; c" => "a &lt;b&gt; c",
      "<p>one</p><p>two</p>" => "onetwo", %("q" 'a') => %("q" 'a'), "<style>x</style>y" => "xy", "&amp;amp;" => "&amp;amp;",
      "<b>bold</b>" => "bold", "</script><img src=a onerror=prompt(1)>" => "", " sp  " => " sp  ",
      "<textarea>t<b>x</b></textarea>" => "t&lt;b&gt;x&lt;/b&gt;", "" => "" }.each do |input, expected|
      assert_equal expected, M.sanitize_field(input), input
    end
    assert_nil M.sanitize_field(nil)
  end
end

class OpengraphOracleTest < Minitest::Test
  FIXTURES = File.join(__dir__, "fixtures")

  def setup
    @spec = JSON.parse(File.read(File.join(FIXTURES, "opengraph_cases.json")))
    @expected = JSON.parse(File.read(File.join(FIXTURES, "opengraph_expected.json")))
    @server = OracleServer.new(@spec["routes"].map { |r| OracleServer.route(r) })
  end

  def teardown = @server.close

  # UnfurlLinksController#create after params.require(:url).
  def unfurl(url)
    controller = Campfire::UnfurlLinksController.allocate
    body = controller.send(:unfurl, url)
    body ? { "status" => 200, "body" => body } : { "status" => 204 }
  rescue StandardError => e
    { "status" => 500, "error" => e.class.name }
  end

  def test_unfurls_like_the_reference
    failures = []
    @spec["cases"].zip(@expected).each do |c, expected|
      assert_equal c["name"], expected["name"]
      FakeNet.install!(@spec["hosts"], @spec["public_ips"], @server.port)
      before = @server.count
      response = unfurl(c["url"])
      requests = @server.received_since(before).map do |r|
        [r.method, r.headers["host"], r.target, r.headers["accept"], r.headers["accept-encoding"], r.headers["user-agent"]]
      end
      actual = { "response" => response, "lookups" => FakeNet.lookups, "requests" => requests }
      wanted = { "response" => expected["response"], "lookups" => expected["lookups"], "requests" => expected["requests"] }
      failures << "#{c["name"]}:\n  expected #{wanted.to_json}\n  actual   #{actual.to_json}" if actual != wanted
    end
    assert failures.empty?, "#{failures.size} of #{@spec["cases"].size} cases differ:\n#{failures.join("\n")}"
  end

  def page_route(path, body, **opts)
    OracleServer::Route.new("GET", "*", path, 200, [["Content-Type", "text/html"]] + (opts[:headers] || []), body.b,
      opts[:chunked], opts[:gzip], opts[:delay] || 0)
  end

  PAGE = %(<meta property="og:title" content="Hey!"><meta property="og:url" content="http://www.example.com/"><meta property="og:description" content="desc..">)

  # A page followed by a gigabyte of zeros, gzipped to a megabyte, is past the
  # 5MB limit as soon as that much is inflated; the same page followed by less unfurls.
  def test_stops_reading_a_gzip_bomb_at_the_limit
    gz = ->(zeros_mb) do
      io = StringIO.new("".b)
      w = Zlib::GzipWriter.new(io)
      w.write(PAGE)
      zero = "\0".b * (1024 * 1024)
      zeros_mb.times { w.write(zero) }
      w.finish
      io.string
    end
    server = OracleServer.new([
      page_route("/", gz.(1024), headers: [["Content-Encoding", "gzip"]]),
      page_route("/small", gz.(2), headers: [["Content-Encoding", "gzip"]])
    ])
    FakeNet.install!({ "www.example.com" => [["93.184.216.34"]] }, ["93.184.216.34"], server.port)
    assert_equal 200, unfurl("http://www.example.com/small")["status"]
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal({ "status" => 204 }, unfurl("http://www.example.com/"))
    assert Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 3
  ensure
    server&.close
  end

  # A server that keeps a request waiting runs into the unfurl's deadline.
  def test_gives_up_at_the_deadline
    server = OracleServer.new([page_route("/", PAGE, delay: 3)])
    FakeNet.install!({ "www.example.com" => [["93.184.216.34"]] }, ["93.184.216.34"], server.port)
    Campfire::UnfurlLinksController.send(:remove_const, :DEADLINE)
    Campfire::UnfurlLinksController.const_set(:DEADLINE, 0.5)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal({ "status" => 204 }, unfurl("http://www.example.com/"))
    assert Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 1.5
  ensure
    Campfire::UnfurlLinksController.send(:remove_const, :DEADLINE)
    Campfire::UnfurlLinksController.const_set(:DEADLINE, 10)
    server&.close
  end
end

# test/controllers/unfurl_links_controller_test.rb, over the fake network.
class UnfurlLinksControllerTest < Minitest::Test
  PAGE = %(<html><head><meta property="og:url" content="https://example.com"><meta property="og:title" content="Hey!"><meta property="og:description" content="desc.."><meta property="og:image" content="http://example.com/image.png"></head></html>)

  def setup
    @server = OracleServer.new([
      OracleServer::Route.new("GET", "www.example.com", "/", 200, [["Content-Type", "text/html"]], PAGE.b, false, false, 0),
      OracleServer::Route.new("HEAD", "example.com", "/image.png", 200, [["Content-Type", "image/png"]], "".b, false, false, 0)
    ])
    FakeNet.install!({ "www.example.com" => [["93.184.216.34"]], "example.com" => [["93.184.216.35"]] },
      ["93.184.216.34", "93.184.216.35"], @server.port)
    @client = AppHarness::Client.new
    @client.csrf!
  end

  def teardown = @server.close

  def post(params, headers = {}) = @client.form("POST", "/unfurl_link", params, headers)

  def test_create
    r = post({ "url" => "http://www.example.com" })
    assert_equal 200, r.status
    assert_equal "application/json; charset=utf-8", r.headers["content-type"]
    assert_equal %({"title":"Hey!","url":"https://example.com","image":"http://example.com/image.png","description":"desc..","context_for_validation":{"context":null},"errors":{}}), r.body
    assert_equal [["93.184.216.34", 80], ["93.184.216.35", 80]], FakeNet.dialed
  end

  def test_create_for_a_private_address_or_a_non_string
    assert_equal 204, post({ "url" => "http://127.0.0.1/secret" }).status
    assert_equal 204, post({ "url[a]" => "http://www.example.com" }).status
    assert_equal 204, post({ "url[]" => "http://www.example.com" }).status
    assert_empty FakeNet.dialed
  end

  def test_create_without_a_url_is_a_bad_request
    r = post({ "url" => "" })
    assert_equal 400, r.status
    assert_equal "text/html; charset=UTF-8", r.headers["content-type"]
    assert_equal "", r.body
    assert_equal 400, post({}).status
    assert_equal 400, post({ "url" => "  " }).status
    r = json_post("url=")
    assert_equal 400, r.status
    assert_equal "application/json; charset=UTF-8", r.headers["content-type"]
    assert_equal %({"status":400,"error":"Bad Request"}), r.body
  end

  # A request whose only Accept is application/json (Mime[formats.first] is JSON).
  def json_post(body)
    cookies = @client.instance_variable_get(:@cookies).map { |k, v| "#{k}=#{v}" }.join("; ")
    h = Protocol::HTTP::Headers.new
    { "user-agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
      "accept" => "application/json", "cookie" => cookies, "x-csrf-token" => @client.csrf,
      "content-type" => "application/x-www-form-urlencoded" }.each { |k, v| h.add(k, v) }
    req = Protocol::HTTP::Request.new("http", AppHarness::HOST, "POST", "/unfurl_link", "HTTP/1.1", h, Protocol::HTTP::Body::Buffered.wrap(body))
    res = AppHarness.app.call(req)
    AppHarness::Response.new(res.status, res.headers.to_h.transform_values(&:to_s), res.body ? res.body.join.to_s : "")
  end

  def test_create_raises_for_an_unreadable_tweet
    assert_equal 500, post({ "url" => "http://twitter.com/missing/status/2" }).status
  end
end
