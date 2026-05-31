# frozen_string_literal: true

# Seed > 1 page of limiters AND batches so you can verify the pagination fix
# in the running dummy app:
#   * Page 1 now shows the FIRST rows (the old off-by-one showed an empty page
#     whenever total <= page size, and skipped the first 25 otherwise).
#   * Next/Prev move between pages with no overlap.
#
# Usage:
#   ruby test/qa/pagination_demo.rb          # seed 30 limiters + 30 batches
#   ruby test/qa/pagination_demo.rb cleanup  # remove them
#
# Then open the dummy app's Limiters and Batches tabs (default port below).

require 'redis-client'
require 'json'

REDIS = RedisClient.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
N = Integer(ENV.fetch('WURK_QA_N', '30'))

def lname(i) = format('pg-lmt-%02d', i)
def bid(i)   = format('pg-batch-%02d', i)

def seed
  N.times do |i|
    REDIS.call('SADD', 'lmtr-list', lname(i))
    REDIS.call('HSET', "lmtr:#{lname(i)}", 'type', 'concurrent', 'fingerprint', 'qa',
               'options', JSON.dump('limit' => 10))
    REDIS.call('HSET', "lmtr-stats:#{lname(i)}", 'immediate', (i * 7).to_s)

    REDIS.call('ZADD', 'batches', (Time.now.to_f + i).to_s, bid(i))
    REDIS.call('HSET', "b-#{bid(i)}", 'total', '10', 'pending', (i % 5).to_s, 'failures', '0',
               'created_at', Time.now.to_f.to_s, 'description', "QA pagination batch #{i}")
    REDIS.call('SADD', "b-#{bid(i)}-jids", 'j1', 'j2')
  end
  puts "Seeded #{N} limiters (pg-lmt-*) and #{N} batches (pg-batch-*)."
  puts 'Limiters/Batches tabs should show "Page 1 of 2", rows starting at #00, Next/Prev working.'
end

def cleanup
  N.times do |i|
    REDIS.call('SREM', 'lmtr-list', lname(i))
    REDIS.call('DEL', "lmtr:#{lname(i)}", "lmtr-stats:#{lname(i)}")
    REDIS.call('ZREM', 'batches', bid(i))
    REDIS.call('DEL', "b-#{bid(i)}", "b-#{bid(i)}-jids")
  end
  puts "Removed #{N} limiters and #{N} batches."
end

ARGV.first == 'cleanup' ? cleanup : seed
