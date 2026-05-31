# frozen_string_literal: true

# QA driver for #25 — Dashboard API: batches, limiters, periodic pages.
#
# Seeds one of each entity into the dummy app's Redis (db 0, no namespace in
# dev) and exercises the three JSON endpoints against a running server, so you
# can see real data flow end-to-end.
#
# Usage:
#   1. Boot the dummy app in another terminal:
#        cd test/dummy && bin/rails s
#   2. Run this driver:
#        ruby test/qa/dashboard_api_25_driver.rb
#   3. Open http://localhost:3000/wurk/#/batches , /#/limiters , /#/cron
#      and confirm the seeded rows render (then click the batch bid → detail).
#
# Re-runnable: it cleans up its own keys at the end.

require 'redis-client'
require 'json'
require 'net/http'
require 'securerandom'

BASE  = ENV.fetch('WURK_QA_BASE', 'http://localhost:3000')
REDIS = RedisClient.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
SUFFIX = SecureRandom.hex(3)

LIMITER = "qa-stripe-#{SUFFIX}"
BID     = "qa-batch-#{SUFFIX}"
LID     = "qa-loop-#{SUFFIX}"

def seed
  # Concurrent limiter + live metric counters (the #status hash the page reads).
  REDIS.call('SADD', 'lmtr-list', LIMITER)
  REDIS.call('HSET', "lmtr:#{LIMITER}", 'type', 'concurrent', 'fingerprint', 'qa',
             'options', JSON.dump('limit' => 5))
  REDIS.call('HSET', "lmtr-stats:#{LIMITER}", 'held', '2', 'immediate', '417', 'waited', '13', 'overages', '1')

  # In-progress batch with one failure (4 live jids of 10 → 40% done).
  REDIS.call('ZADD', 'batches', Time.now.to_f.to_s, BID)
  REDIS.call('HSET', "b-#{BID}", 'total', '10', 'pending', '4', 'failures', '1',
             'created_at', Time.now.to_f.to_s, 'description', "QA nightly export #{SUFFIX}")
  REDIS.call('SADD', "b-#{BID}-jids", 'j1', 'j2', 'j3', 'j4')
  REDIS.call('SADD', "b-#{BID}-failed", 'jf1')

  # Periodic loop that fired 30s ago.
  REDIS.call('SADD', 'periodic', LID)
  REDIS.call('HSET', "loops:#{LID}", 'schedule', '*/5 * * * *', 'klass', 'HardJob',
             'queue', 'default', 'options', '{}', 'tz', '', 'paused', '0')
  REDIS.call('LPUSH', "loop-history:#{LID}", JSON.dump([Time.now.to_i - 30, 'qa-jid']))
end

def cleanup
  REDIS.call('SREM', 'lmtr-list', LIMITER)
  REDIS.call('DEL', "lmtr:#{LIMITER}", "lmtr-stats:#{LIMITER}")
  REDIS.call('ZREM', 'batches', BID)
  REDIS.call('DEL', "b-#{BID}", "b-#{BID}-jids", "b-#{BID}-failed")
  REDIS.call('SREM', 'periodic', LID)
  REDIS.call('DEL', "loops:#{LID}", "loop-history:#{LID}")
end

def get(path)
  res = Net::HTTP.get_response(URI("#{BASE}#{path}"))
  [res.code, JSON.parse(res.body)]
rescue Errno::ECONNREFUSED
  abort "\n✗ Could not reach #{BASE}. Boot the dummy app first:\n    cd test/dummy && bin/rails s\n"
end

def show(title, path)
  code, body = get(path)
  rows = body.is_a?(Hash) ? (body['batches'] || body['limiters'] || body['entries'] || [body]) : body
  puts "\n#{title}  (#{path})  → HTTP #{code}, #{rows.is_a?(Array) ? rows.size : 1} row(s)"
  puts JSON.pretty_generate(body)
end

seed
puts "Seeded limiter=#{LIMITER}  batch=#{BID}  loop=#{LID}"

show 'LIMITERS', '/wurk/api/limiters'
show 'BATCHES',  '/wurk/api/batches'
show 'BATCH DETAIL', "/wurk/api/batches/#{BID}"
show 'PERIODIC', '/wurk/api/cron'

puts "\n— Manual check —"
puts "Open #{BASE}/wurk/ and visit Limiters / Batches / Cron in the sidebar."
puts "On Limiters: row '#{LIMITER}' (concurrent) shows a usage gauge (used/limit) + 'available'"
puts "             badge and a Reset button; hover Used to see its metric counters."
puts "On Batches:  row '#{BID}' is 40% with 1 failure; click the bid → detail page."
puts "On Cron:     row schedule '*/5 * * * *' shows a 'Last fire' ~30s ago, Pause/Enqueue buttons."

print "\nPress Enter to clean up seeded keys... "
$stdin.gets
cleanup
puts 'Cleaned up.'
