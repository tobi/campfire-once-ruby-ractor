# Summarise a parity compare output dir: failing layers per state, and network-layer
# differences grouped by request pattern (ids/digests collapsed).
#   ruby bench/parity-summary.rb ../ref-rust/parity/out/ruby-run1-default [...]
require "json"

SESSION_COOKIES = /\A {2}set-cookie: (_campfire_session|session_token|last_room)\b/

def entries(file)
  return {} unless File.exist?(file)
  File.read(file).split(/^(?=\S)/).to_h do |block|
    head, *rest = block.lines
    # parity/capture/divergences.ts masks the session cookies Rails re-sends on every response.
    lines = rest.map(&:rstrip).reject { |l| l.start_with?("  body:") || l.match?(SESSION_COOKIES) }
    lines.map! { |l| l.start_with?("  headers:") ? l.sub(/ set-cookie\b/, "") : l }
    [head.strip, lines.join("\n")]
  end
end

def pattern(line) = line.gsub(/-[0-9a-f]{8}\./, "-DIGEST.").gsub(/\d{3,}/, "N").gsub(/[A-Za-z0-9_-]{20,}={0,2}/, "TOKEN")

layers = Hash.new { |h, k| h[k] = [] }
net = Hash.new { |h, k| h[k] = { states: [], ref: nil, cand: nil } }
ARGV.each do |dir|
  report = JSON.parse(File.read(File.join(dir, "report.json")))
  report["results"].each do |r|
    next if r["status"] == "pass"
    bad = (r["layers"] || []).reject { |l| l["equal"] }.map { |l| l["layer"] }
    bad = [r["status"]] if bad.empty?
    bad.each { |l| layers[l] << "#{r["state"]}@#{r["cell"]}" }
    next unless bad.include?("network")
    ref = entries(File.join(dir, "reference", r["state"], "#{r["cell"]}.network.txt"))
    cand = entries(File.join(dir, "candidate", r["state"], "#{r["cell"]}.network.txt"))
    (ref.keys | cand.keys).each do |k|
      next if ref[k] == cand[k]
      e = net[[pattern(k), ref[k], cand[k]]]
      e[:states] << r["state"]
    end
  end
end

puts "== failing layers (cells)"
layers.sort_by { |_, v| -v.size }.each do |l, cells|
  states = cells.map { |c| c.split("@").first }.uniq
  puts "#{l}: #{cells.size} cells, #{states.size} states"
  puts "   " + states.first(60).join(" ") if l != "network"
end
puts "\n== network differences by request pattern"
net.group_by { |(pat, _, _), _| pat }.sort_by { |_, v| -v.sum { |_, e| e[:states].uniq.size } }.each do |pat, variants|
  states = variants.flat_map { |_, e| e[:states] }.uniq
  puts "#{pat}   (#{states.size} states: #{states.first(4).join(", ")})"
  variants.first(2).each do |(_, ref, cand), _|
    puts "  ref:  #{(ref || "MISSING").gsub("\n", " | ")}"
    puts "  ours: #{(cand || "MISSING").gsub("\n", " | ")}"
  end
end
