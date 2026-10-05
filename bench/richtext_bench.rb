# frozen_string_literal: true

# Throughput and allocation benchmark for Campfire::RichText.
#
#   mise exec -- ruby -Ilib bench/richtext_bench.rb          # interpreter
#   mise exec -- ruby --yjit -Ilib bench/richtext_bench.rb   # YJIT
#
# For each case prints presentation renders/sec and objects allocated per
# render (GC.stat(:total_allocated_objects) delta), then the same for
# plain_text and for render (all six fields).

require_relative "../lib/campfire/rich_text"

RT = Campfire::RichText
SECRET = "5335c3b1ad35b4ad170c3413bd651ef3b6ed64e257261871a6de3f978cf3868ee417a927040935fb30b0f7debdedb34a2a403e9f34b16cf594c917c2ecd4a995"
VERIFIER = RT::SGID::Verifier.new(SECRET)
USERS = {
  1 => RT::User.new(1, "David", "David – Founder", VERIFIER.generate("gid://campfire/User/1?expires_in"), "/users/1", "/users/1/avatar")
}.freeze
RESOLVER = ->(id) { USERS[id] }
SGID = USERS[1].attachable_sgid
HOST = "once.campfire.test"

CASES = {
  "plain text" => "Hello everyone, lunch is at noon!",
  "paragraph + link" => "<p>Have you seen https://basecamp.com/handbook? It's great &amp; short.</p>",
  "formatted" => "<div>Shipping <strong>today</strong>:<ul><li>one</li><li><em>two</em></li></ul><blockquote>quote</blockquote></div>",
  "mention" => %(<p>Hey <action-text-attachment sgid="#{SGID}" content-type="application/vnd.campfire.mention"></action-text-attachment>, ping me@example.com</p>),
  "opengraph embed" => %(<p>https://basecamp.com/</p><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="&lt;div class=&quot;og-embed__title&quot;&gt;&lt;a href=&quot;https://basecamp.com/&quot;&gt;Basecamp&lt;/a&gt;&lt;/div&gt;&lt;div class=&quot;og-embed__description&quot;&gt;Project management&lt;/div&gt;"></action-text-attachment>),
  "trix image" => %(<div><figure data-trix-attachment="{&quot;contentType&quot;:&quot;image/png&quot;,&quot;url&quot;:&quot;https://example.com/a.png&quot;,&quot;width&quot;:640,&quot;height&quot;:480}" data-trix-attributes="{&quot;caption&quot;:&quot;Look&quot;}"></figure></div>),
  "long message" => "<div>#{(["Lorem ipsum dolor sit amet, <b>consectetur</b> adipiscing elit http://example.com/x."] * 20).join("<br>")}</div>",
  "hostile markup" => %(<p onclick="x()">a<script>alert(1)</script><img src=x onerror=y><a href="javascript:alert(1)">l</a><table><td>c</table><svg><a xlink:href="javascript:1">s</a></svg></p>)
}.freeze

def measure(seconds = 0.5)
  yield # warm up
  n = 0
  GC.start
  allocated = GC.stat(:total_allocated_objects)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = start + seconds
  while (now = Process.clock_gettime(Process::CLOCK_MONOTONIC)) < deadline
    10.times { yield }
    n += 10
  end
  [n / (now - start), (GC.stat(:total_allocated_objects) - allocated) / n.to_f]
end

def report(label, rows)
  puts "\n#{label}"
  puts format("  %-20s %12s %14s", "case", "renders/s", "allocs/render")
  total_rate = total_allocs = 0.0
  rows.each do |name, (rate, allocs)|
    puts format("  %-20s %12.0f %14.0f", name, rate, allocs)
    total_rate += 1 / rate
    total_allocs += allocs
  end
  puts format("  %-20s %12.0f %14.0f", "(mix, harmonic)", rows.size / total_rate, total_allocs / rows.size)
end

puts "ruby #{RUBY_VERSION} yjit=#{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "on" : "off"}"
report("presentation", CASES.map { |name, body| [name, measure { RT.presentation(body, host: HOST, resolver: RESOLVER) }] })
report("plain_text", CASES.map { |name, body| [name, measure { RT.plain_text(body, resolver: RESOLVER) }] })
report("render (all fields)", CASES.map { |name, body| [name, measure { RT.render(body, host: HOST, resolver: RESOLVER, verifier: VERIFIER) }] })
