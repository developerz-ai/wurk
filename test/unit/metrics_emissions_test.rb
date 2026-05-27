# frozen_string_literal: true

require_relative '../test_helper'

# Covers the StatsD emission sites wired through hot paths (issue #21):
# Client#push / #push_bulk, JobRetry#schedule_retry, Heartbeat#beat!.
# Each test sets `Wurk.configuration.dogstatsd` to a recording FakeClient and
# inspects the calls list. Wrapped in `Wurk::Test::STATSD_MUTEX` because the
# `Statsd` singleton state is process-global and serializes with the other
# statsd-touching test files.
class MetricsEmissionsTest < Wurk::Test::UnitCase
  parallelize_me!

  def run(*args, &)
    Wurk::Test::STATSD_MUTEX.synchronize { super }
  end

  class FakeClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def increment(metric, **opts) = @calls << [:increment, metric, opts]
    def gauge(metric, value, **opts) = @calls << [:gauge, metric, value, opts]
    def distribution(metric, value, **opts) = @calls << [:distribution, metric, value, opts]
  end

  def setup
    super
    @ns = "me:#{Process.pid}:#{object_id}"
    @prev_builder = Wurk.configuration.dogstatsd
    Wurk::Metrics::Statsd.reset!
    @fake = FakeClient.new
    Wurk.configuration.dogstatsd = @fake
  end

  def teardown
    Wurk.configuration.dogstatsd = @prev_builder
    Wurk::Metrics::Statsd.reset!
  ensure
    super
  end

  # --- Client#push --------------------------------------------------------

  def test_push_emits_jobs_enqueued_with_worker_and_queue_tags
    Wurk::Client.new.push('class' => 'MyJob', 'queue' => @ns, 'args' => [])

    enq = @fake.calls.find { |c| c[1] == 'sidekiq.jobs.enqueued' }

    refute_nil enq, 'expected sidekiq.jobs.enqueued increment'
    assert_equal ["worker:MyJob", "queue:#{@ns}"], enq[2][:tags]
  ensure
    cleanup_queue
  end

  def test_push_skips_emit_when_middleware_halts
    halt = Class.new do
      def call(_w, _job, _q, _r); end # returns nil → halt
    end
    Wurk.configuration.client_middleware.add(halt)
    begin
      Wurk::Client.new.push('class' => 'MyJob', 'queue' => @ns, 'args' => [])
    ensure
      Wurk.configuration.client_middleware.remove(halt)
    end

    assert_nil @fake.calls.find { |c| c[1] == 'sidekiq.jobs.enqueued' }
  end

  def test_push_bulk_emits_one_jobs_enqueued_per_payload
    Wurk::Client.new.push_bulk('class' => 'MyJob', 'queue' => @ns, 'args' => [[1], [2], [3]])

    enq = @fake.calls.select { |c| c[1] == 'sidekiq.jobs.enqueued' }

    assert_equal 3, enq.size
  ensure
    cleanup_queue
  end

  # --- JobRetry#schedule_retry -------------------------------------------

  def test_schedule_retry_emits_jobs_retried_with_tags
    msg = { 'class' => 'FailingJob', 'queue' => @ns, 'jid' => 'abc' }
    retry_handler = Wurk::JobRetry.new(Wurk.configuration)
    retry_handler.send(:schedule_retry, msg, 1, 0)

    ret = @fake.calls.find { |c| c[1] == 'sidekiq.jobs.retried' }

    refute_nil ret
    assert_equal ["worker:FailingJob", "queue:#{@ns}"], ret[2][:tags]
  ensure
    # schedule_retry doesn't mutate msg, so the ZADDed payload is exactly
    # `dump_json(msg)`. ZREM that single entry only — wiping the whole zset
    # would clobber any concurrently-running parallel test's retry data.
    Wurk.redis { |c| c.call('ZREM', Wurk::Keys::RETRY, Wurk.dump_json(msg)) } if defined?(msg)
  end

  # --- Heartbeat#beat! ----------------------------------------------------

  def test_beat_emits_busy_gauge_tagged_with_process_identity
    hb = build_heartbeat
    hb.beat!

    busy = @fake.calls.find { |c| c[0] == :gauge && c[1] == 'sidekiq.busy' }

    refute_nil busy
    assert_equal ["process:#{@identity}"], busy[3][:tags]
  ensure
    cleanup_heartbeat
  end

  def test_beat_emits_queue_size_gauge_per_capsule_queue
    Wurk.redis { |c| c.call('LPUSH', "queue:#{@ns}", '{}') }

    hb = build_heartbeat
    hb.beat!

    qs = @fake.calls.find { |c| c[0] == :gauge && c[1] == 'sidekiq.queue.size' }

    refute_nil qs
    assert_equal 1, qs[2]
    assert_includes qs[3][:tags], "queue:#{@ns}"
    assert_includes qs[3][:tags], "process:#{@identity}"
  ensure
    Wurk.redis { |c| c.call('UNLINK', "queue:#{@ns}") }
    cleanup_heartbeat
  end

  def test_beat_skips_emissions_when_no_dogstatsd_client
    Wurk.configuration.dogstatsd = nil
    Wurk::Metrics::Statsd.reset!

    hb = build_heartbeat
    hb.beat!

    assert_empty @fake.calls
  ensure
    cleanup_heartbeat
  end

  def test_beat_swallows_metrics_failure
    boom_pool = Object.new
    boom_pool.define_singleton_method(:gauge) { |*_, **_| raise 'boom' }
    Wurk.configuration.dogstatsd = boom_pool

    hb = build_heartbeat

    assert_equal [], hb.beat!, 'beat must still return signals when metrics raise'
  ensure
    cleanup_heartbeat
  end

  private

  def build_heartbeat
    @hb_config = Wurk::Configuration.new
    @hb_config.logger = ::Logger.new(IO::NULL)
    cap = @hb_config.default_capsule
    cap.queues = [@ns]
    cap.concurrency = 1
    @identity = "host-#{@ns}:1234:#{object_id.to_s(16)}"
    @hb_cleanup = [@identity, "#{@identity}:work", "#{@identity}-signals"]
    Wurk::Heartbeat.new(
      identity: @identity,
      config: @hb_config,
      started_at: Time.now.to_f,
      embedded: false
    )
  end

  def cleanup_heartbeat
    return unless defined?(@hb_cleanup)

    @hb_config.redis_pool.with do |c|
      c.call('SREM', Wurk::Keys::PROCESSES, @identity)
      @hb_cleanup.each { |k| c.call('UNLINK', k) }
    end
  end

  def cleanup_queue
    Wurk.redis { |c| c.call('UNLINK', "queue:#{@ns}") }
  end
end
