# frozen_string_literal: true

# QA driver for #22 — Metrics history time-series.
#
# Seeds ~45 minutes of per-class minute buckets (the source `j|` hashes the
# History middleware writes), then runs the REAL Wurk::Metrics::Rollup to fold
# them into the cluster-total jr|1m / jr|5m / jr|1h buckets — exactly what the
# leader thread does in production. Finally it reads them back via the live
# /api/history endpoint so you can see end-to-end flow, then points you at the
# dashboard chart.
#
# Usage:
#   1. Boot the dummy app:   cd test/dummy && bin/rails s   (or use a running one)
#   2. ruby test/qa/metrics_history_driver.rb               (WURK_QA_BASE overrides port)
#
# Re-runnable; cleans up every key it wrote on Enter.

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'wurk'
require 'wurk/metrics/rollup'
require 'net/http'
require 'json'

BASE = ENV.fetch('WURK_QA_BASE', 'http://localhost:3000')
MINUTES = 45
NOW = Time.now.utc

# Seed source minute buckets with a rising throughput curve + a few failures.
seeded = []
MINUTES.downto(1) do |i|
  t = NOW - (i * 60)
  processed = 20 + ((MINUTES - i) * 3) + rand(10)
  failed = (i % 7).zero? ? rand(1..4) : 0
  key = Wurk::Metrics::History.minute_key(t)
  seeded << key
  Wurk.redis do |c|
    c.call('HSET', key, 'DemoJob|p', processed, 'DemoJob|f', failed, 'DemoJob|ms', processed * 35)
  end
end

# Run the real rollup once per minute boundary so every bucket is populated.
rollup = Wurk::Metrics::Rollup.new(Wurk.configuration)
MINUTES.downto(0) { |i| rollup.roll(NOW - (i * 60)) }

def history(path)
  res = Net::HTTP.get_response(URI("#{BASE}#{path}"))
  [res.code, JSON.parse(res.body)]
rescue Errno::ECONNREFUSED
  abort "\n✗ Could not reach #{BASE}. Boot the dummy app: cd test/dummy && bin/rails s\n"
end

puts "Seeded #{MINUTES} minutes of source data and rolled it into jr|1m/5m/1h.\n\n"
# Widen each query past the seeded span so an hour-boundary tick can't hide the
# single 1h bucket the data falls in.
{ '1m' => '2h', '5m' => '3h', '1h' => '6h' }.each do |bucket, window|
  code, body = history("/wurk/api/history/#{bucket}?window=#{window}")
  pts = body.is_a?(Hash) ? (body['series'] || []) : []
  nonzero = pts.count { |p| p['processed'].to_i.positive? }
  last = pts.reverse.find { |p| p['processed'].to_i.positive? }
  puts "#{bucket} (#{window}): HTTP #{code}, #{nonzero}/#{pts.size} non-zero points; latest = #{last.inspect}"
end

puts "\n— Manual check —"
puts "Open #{BASE}/wurk/#/metrics — the 'Throughput & Failures' card (top) should show a"
puts "rising Processed line with occasional Failed spikes. Switch the range selector"
puts "(24h·1m / 7d·5m / 30d·1h) to read the different rollup buckets."

print "\nPress Enter to clean up seeded keys... "
$stdin.gets

Wurk.redis do |c|
  c.call('DEL', *seeded) unless seeded.empty?
  %w[1m 5m 1h].each do |bucket|
    step = Wurk::Metrics::Rollup::BUCKETS[bucket][0]
    starts = (0..(3600 / step)).map { |i| ((NOW.to_i / step) * step) - (i * step) }
    keys = starts.map { |s| Wurk::Metrics::Rollup.bucket_key(bucket, s) }
    c.call('DEL', *keys)
  end
end
puts 'Cleaned up.'
