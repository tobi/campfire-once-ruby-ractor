# frozen_string_literal: true

# Summarise a bench/run-all results dir as Markdown: for every metric, mean ± sample standard
# deviation across reps (each rep is a fresh container), plus the median. Latency rows report the
# per-run percentile (p50/p90/p99 over every request of that run), aggregated across reps the
# same way.
#
#   ruby bench/stats.rb bench/results/<stamp> [--json]
require "json"

dir = ARGV.fetch(0)
APP_ORDER = %w[reference go rust ruby ruby-head ruby-zjit rust-identity].freeze
NAMES = { "reference" => "Rails", "go" => "Go", "rust" => "Rust", "ruby" => "Ruby", "ruby-head" => "Ruby head", "ruby-zjit" => "Ruby head ZJIT", "rust-identity" => "Rust (no gzip)" }.freeze

runs = Hash.new { |h, k| h[k] = [] }
Dir[File.join(dir, "*-*.json")].sort.each do |f|
  r = JSON.parse(File.read(f))
  runs[r["app"]] << r if r.is_a?(Hash) && r["app"]
end
apps = APP_ORDER.select { |a| runs.key?(a) }

def stats(vals)
  vals = vals.compact.map(&:to_f)
  return nil if vals.empty?
  n = vals.size
  mean = vals.sum / n
  sd = n > 1 ? Math.sqrt(vals.sum { |v| (v - mean)**2 } / (n - 1)) : 0.0
  sorted = vals.sort
  median = n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
  { n: n, mean: mean, sd: sd, median: median, min: sorted.first, max: sorted.last }
end

def fmt(v)
  return "–" if v.nil?
  a = v.abs
  a >= 100 ? v.round.to_s.reverse.scan(/\d{1,3}/).join(",").reverse : a >= 10 ? format("%.1f", v) : format("%.2f", v)
end

def cell(s) = s ? "#{fmt(s[:mean])} ± #{fmt(s[:sd])}" : "–"

def dig(r, path)
  path.reduce(r) { |o, k| o.is_a?(Array) ? o.find { |x| k.call(x) } : o&.[](k) }
end

table = lambda do |title, rows|
  puts "\n### #{title}\n\n"
  puts "| Metric | #{apps.map { NAMES[_1] }.join(" | ")} |"
  puts "|---|#{apps.map { "---:" }.join("|")}|"
  rows.each do |label, getter|
    cells = apps.map { |a| cell(stats(runs[a].map { |r| (getter.call(r) rescue nil) })) }
    next if cells.all?("–")
    puts "| #{label} | #{cells.join(" | ")} |"
  end
end

puts "## Results: #{File.basename(dir)}"
puts "\nmean ± sd across reps (#{apps.map { "#{NAMES[_1]} n=#{runs[_1].size}" }.join(", ")}). Each rep is a fresh container on a fresh seed copy."
env = File.join(dir, "env.txt")
puts "\n```\n#{File.read(env).strip}\n```" if File.exist?(env)

routes = runs.values.flatten.flat_map { |r| r["http"] || [] }.map { |h| [h["route"], h["conc"]] }.uniq
routes.map(&:first).uniq.each do |route|
  rows = []
  routes.select { |r, _| r == route }.map(&:last).sort.each do |conc|
    h = ->(r) { r["http"].find { |x| x["route"] == route && x["conc"] == conc } }
    rows << ["c=#{conc} req/s", ->(r) { h.(r)["rps"] }]
    %w[p50 p90 p99].each { |p| rows << ["c=#{conc} #{p} ms", ->(r) { h.(r)["latency"]["#{p}_ms"] }] }
    rows << ["c=#{conc} non-2xx/3xx", ->(r) { x = h.(r); x["statuses"].sum { |k, v| k.to_i >= 400 ? v : 0 } + x["errors"].to_i }]
  end
  table.call("HTTP #{route}", rows)
end

cable_ns = runs.values.flatten.flat_map { |r| r["cable"] || [] }.map { |c| c["clients"] }.compact.uniq.sort
unless cable_ns.empty?
  rows = []
  cable_ns.each do |n|
    c = ->(r) { r["cable"].find { |x| x["clients"] == n } }
    rows << ["#{n} clients: delivery p50 ms", ->(r) { c.(r)["latency"]["all_clients"]["p50_ms"] }]
    rows << ["#{n} clients: delivery p99 ms", ->(r) { c.(r)["latency"]["all_clients"]["p99_ms"] }]
    rows << ["#{n} clients: delivered msg/s", ->(r) { c.(r)["throughput"]["delivered_msgs_per_sec"] }]
  end
  table.call("Action Cable fan-out", rows)
end

table.call("Process", [
  ["cold start ms", ->(r) { r["cold_start_ms"] }],
  ["idle memory MB", ->(r) { r["memory"]["idle_current_mb"] }],
  ["peak memory MB", ->(r) { r["memory"]["cgroup_peak_mb"] }],
  ["upload median ms", ->(r) { r["upload"]["median_total_ms"] }]
])
