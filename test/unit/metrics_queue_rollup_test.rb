# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'
require 'wurk/metrics/queue_rollup'
require 'wurk/metrics/query'

# QueueRollup samples per-queue depth + head-of-line latency into time buckets
# (`qm|<bucket>|<epoch>` HASH, `<queue>|sz` / `<queue>|lt` fields). Like the
# cluster-total rollup these buckets are keyed only by time, so each test picks
# a unique minute-aligned epoch (PID:object_id) and unique queue names, then
# DELs exactly its own keys on teardown.
class MetricsQueueRollupTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @epoch_min = ((2_000_000_000 + ((Process.pid % 100_000) * 100_000) + (object_id % 100_000)) / 60) * 60
    @at = ::Time.at(@epoch_min).utc
    @q1 = "qmq-#{SecureRandom.hex(5)}-a"
    @q2 = "qmq-#{SecureRandom.hex(5)}-b"
    @qr = Wurk::Metrics::QueueRollup.new(Wurk.configuration)
  end

  def teardown
    Wurk.redis do |c|
      keys = Wurk::Metrics::QueueRollup::BUCKETS.map do |bucket, (step, _ttl)|
        Wurk::Metrics::QueueRollup.bucket_key(bucket, (@epoch_min / step) * step)
      end
      c.call('DEL', *keys, "queue:#{@q1}", "queue:#{@q2}")
      c.call('SREM', 'queues', @q1, @q2)
    end
  ensure
    super
  end

  def test_sample_writes_size_for_each_queue_at_every_resolution
    seed_queue(@q1, depth: 3)
    seed_queue(@q2, depth: 1)
    @qr.sample(@at)

    Wurk::Metrics::QueueRollup::BUCKETS.each_key do |bucket|
      h = bucket_hash(bucket)

      assert_equal '3', h["#{@q1}|sz"], "#{bucket} size for #{@q1}"
      assert_equal '1', h["#{@q2}|sz"], "#{bucket} size for #{@q2}"
    end
  end

  def test_sample_records_head_of_line_latency
    # Tail of the LIST is the oldest waiting job; seed it ~90s old.
    seed_queue(@q1, depth: 1, head_age_s: 90)
    @qr.sample(@at)

    latency = bucket_hash('1m')["#{@q1}|lt"].to_f

    assert_operator latency, :>=, 85, 'head-of-line latency should reflect the oldest job'
    assert_operator latency, :<=, 200
  end

  def test_sample_sets_per_bucket_retention_ttls
    seed_queue(@q1, depth: 1)
    @qr.sample(@at)

    Wurk::Metrics::QueueRollup::BUCKETS.each do |bucket, (step, ttl)|
      actual = Wurk.redis { |c| c.call('TTL', Wurk::Metrics::QueueRollup.bucket_key(bucket, (@epoch_min / step) * step)) }

      assert_operator actual, :>, ttl - 120, "#{bucket} ttl too low"
      assert_operator actual, :<=, ttl, "#{bucket} ttl too high"
    end
  end

  def test_sample_is_a_noop_when_no_queues
    @qr.sample(@at) # nothing seeded

    assert_empty bucket_hash('1m')
  end

  # A malformed tail payload on one queue must not abort the whole pass: that
  # queue records latency 0.0 and the healthy queue is still sampled.
  def test_sample_tolerates_a_malformed_queue_payload
    Wurk.redis do |c|
      c.call('SADD', 'queues', @q1, @q2)
      c.call('LPUSH', "queue:#{@q1}", 'not-json{') # bad JSON
      c.call('LPUSH', "queue:#{@q2}", Wurk.dump_json([1, 2])) # valid JSON, wrong shape
    end
    @qr.sample(@at)
    h = bucket_hash('1m')
    fields = ["#{@q1}|sz", "#{@q1}|lt", "#{@q2}|sz", "#{@q2}|lt"]

    assert_equal({ "#{@q1}|sz" => '1', "#{@q1}|lt" => '0.0', "#{@q2}|sz" => '1', "#{@q2}|lt" => '0.0' },
                 h.slice(*fields))
  end

  def test_tick_samples_when_leader
    seed_queue(@q1, depth: 2)
    @qr.define_singleton_method(:leader?) { true }
    @qr.tick(now: @at)

    assert_equal '2', bucket_hash('1m')["#{@q1}|sz"]
  end

  def test_tick_is_leader_gated
    seed_queue(@q1, depth: 2)
    @qr.define_singleton_method(:leader?) { false }
    @qr.tick(now: @at)

    assert_empty bucket_hash('1m')
  end

  # Exercises the spawned-thread `until @done` loop without a fixed sleep.
  # rubocop:disable Metrics/AbcSize
  def test_start_loop_samples_until_terminated
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:metrics_rollup_interval] = 0.01
    qr = Wurk::Metrics::QueueRollup.new(config)
    qr.define_singleton_method(:leader?) { true }
    qr.define_singleton_method(:sample) { |_now = ::Time.now| @ticks = (@ticks || 0) + 1 }

    qr.start
    poll_until(2.0) { qr.instance_variable_get(:@ticks).to_i.positive? }
    qr.terminate

    assert_operator qr.instance_variable_get(:@ticks).to_i, :>, 0
  end
  # rubocop:enable Metrics/AbcSize

  private

  def poll_until(timeout)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    sleep(0.005) until yield || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
  end

  # Push `depth` jobs; the head-of-line job (LIST tail, oldest) is `head_age_s`
  # seconds old. Enqueue with LPUSH so the tail is the oldest, matching the
  # client's FIFO convention (Queue#latency reads the tail).
  def seed_queue(name, depth:, head_age_s: 0)
    Wurk.redis do |c|
      c.call('SADD', 'queues', name)
      depth.times do |i|
        age = i.zero? ? head_age_s : 0
        c.call('LPUSH', "queue:#{name}",
               Wurk.dump_json('class' => 'J', 'args' => [], 'enqueued_at' => ::Time.now.to_f - age))
      end
    end
  end

  def bucket_hash(bucket)
    step = Wurk::Metrics::QueueRollup::BUCKETS[bucket][0]
    raw = Wurk.redis { |c| c.call('HGETALL', Wurk::Metrics::QueueRollup.bucket_key(bucket, (@epoch_min / step) * step)) }
    raw.is_a?(::Array) ? raw.each_slice(2).to_h : raw
  end
end
