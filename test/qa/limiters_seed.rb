# frozen_string_literal: true

# Seed a handful of sample limiters into the dummy app's Redis so the
# dashboard Limiters tab has something to show — then test the per-row Reset
# button (it zeroes the concurrent counters live).
#
# Usage:
#   ruby test/qa/limiters_seed.rb          # seed (rows persist for browsing)
#   ruby test/qa/limiters_seed.rb cleanup  # remove the seeded rows
#
# Open http://localhost:3009/wurk/#/limiters (or your dummy app's port).
# Click "Reset" on `qa-stripe` and watch Held/Immediate/Waited/Overages → 0.

require 'redis-client'
require 'json'

REDIS = RedisClient.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
LIST_KEY = 'lmtr-list'

# name => [type, options-hash, stats-hash-or-nil]
# Only `concurrent` carries metric counters; the others render `—` per spec.
SAMPLES = {
  'qa-stripe' => ['concurrent', { 'limit' => 5 },
                  { 'held' => 3, 'immediate' => 1240, 'waited' => 88, 'wait_time' => 4100,
                    'overages' => 2, 'reclaimed' => 5 }],
  'qa-mailgun' => ['concurrent', { 'limit' => 20 },
                   { 'held' => 0, 'immediate' => 50_310, 'waited' => 0, 'overages' => 0, 'reclaimed' => 12 }],
  'qa-reports' => ['window', { 'count' => 100, 'interval' => 'minute' }, nil],
  'qa-exports' => ['bucket', { 'count' => 10, 'interval' => 'second' }, nil]
}.freeze

def seed
  SAMPLES.each do |name, (type, options, stats)|
    REDIS.call('SADD', LIST_KEY, name)
    REDIS.call('HSET', "lmtr:#{name}", 'type', type, 'fingerprint', 'qa', 'options', JSON.dump(options))
    REDIS.call('HSET', "lmtr-stats:#{name}", *stats.flatten.map(&:to_s)) if stats
  end
  puts "Seeded #{SAMPLES.size} limiters: #{SAMPLES.keys.join(', ')}"
  puts 'Open the Limiters tab to see each type with a usage gauge + status badge.'
  puts 'Click Reset on `qa-stripe` to clear its counters (hover Used to inspect them).'
end

def cleanup
  SAMPLES.each_key do |name|
    REDIS.call('SREM', LIST_KEY, name)
    REDIS.call('DEL', "lmtr:#{name}", "lmtr-stats:#{name}")
  end
  puts "Removed #{SAMPLES.size} seeded limiters."
end

ARGV.first == 'cleanup' ? cleanup : seed
