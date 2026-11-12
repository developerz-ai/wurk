# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::Metrics::Prometheus against real Redis seeded with Sidekiq-shaped keys.
# The exposition is parsed by a strict line grammar (text format 0.0.4) rather
# than substring-matched, so a malformed line fails the parse, not just a value.
class MetricsPrometheusTest < Wurk::Test::UnitCase
  parallelize_me!

  NONCE = 'abc123abc123'
  HOST = 'metrics-host'

  METRIC_LINE = /\A([a-zA-Z_:][a-zA-Z0-9_:]*)(\{(.*)\})? (-?(?:\d+(?:\.\d+)?(?:e[+-]?\d+)?|NaN|[+-]Inf))\z/
  LABEL_PAIR = /\A([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"\z/

  def setup
    @config = Wurk::Configuration.new
    @config.redis = { url: Wurk::Test.redis_url }
    @config.logger = ::Logger.new(IO::NULL)
    @now = 1000.0
    @collector = Wurk::Metrics::Prometheus.new(@config, nonce: NONCE, hostname: HOST, clock: -> { @now })
    @redis = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @redis&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_scrape_parses_and_matches_seeded_redis
    seed
    families = parse(@collector.render(expected_children: 3, fresh_window: 30))

    assert_in_delta(1.0, families['wurk_redis_up'][{}])
    assert_in_delta(1.0, families['wurk_build_info'][{ 'version' => Wurk::VERSION, 'ruby_version' => RUBY_VERSION }])
    assert_in_delta(42.0, families['wurk_processed_total'][{}])
    assert_in_delta(7.0, families['wurk_failed_total'][{}])
    assert_in_delta(2.0, families['wurk_queue_size'][{ 'queue' => 'default' }])
    assert_in_delta(0.0, families['wurk_queue_size'][{ 'queue' => 'empty' }])
    assert_in_delta 120.0, families['wurk_queue_latency_seconds'][{ 'queue' => 'default' }], 5.0
    assert_in_delta(0.0, families['wurk_queue_latency_seconds'][{ 'queue' => 'empty' }])
    assert_in_delta(1.0, families['wurk_scheduled_size'][{}])
    assert_in_delta(2.0, families['wurk_retry_size'][{}])
    assert_in_delta(3.0, families['wurk_dead_size'][{}])
    assert_in_delta(3.0, families['wurk_processes'][{}], 0.001, 'the expired identity is not a process')
    assert_in_delta(6.0, families['wurk_busy'][{}])
    assert_in_delta(30.0, families['wurk_concurrency'][{}])
    assert_in_delta 0.0, families['wurk_scheduler_lag_seconds'][{ 'set' => 'retry' }], 1.0
    assert_in_delta(0.0, families['wurk_scheduler_lag_seconds'][{ 'set' => 'schedule' }], 0.001, 'not due yet')
  end

  def test_scheduler_lag_is_the_age_of_the_earliest_due_member
    @redis.call('ZADD', 'retry', Time.now.to_f - 90, '{"late":1}')

    assert_in_delta 90.0, parse(@collector.render)['wurk_scheduler_lag_seconds'][{ 'set' => 'retry' }], 5.0
  end

  def test_local_families_cover_only_this_process_group
    seed
    families = parse(@collector.render(expected_children: 3, fresh_window: 30))

    assert_in_delta(3.0, families['wurk_swarm_children_expected'][{}])
    assert_in_delta(1.0, families['wurk_swarm_children_fresh'][{}], 0.001, 'pid 102 beat 100s ago — not fresh')
    assert_equal({ { 'pid' => '101' } => 2.0, { 'pid' => '102' } => 1.0 }, families['wurk_process_busy'])
    assert_equal 2048.0 * 1024, families['wurk_process_rss_bytes'][{ 'pid' => '101' }]
    assert_in_delta(1.0, families['wurk_process_quiet'][{ 'pid' => '102' }])
    assert_in_delta 100.0, families['wurk_process_heartbeat_age_seconds'][{ 'pid' => '102' }], 5.0
  end

  def test_expected_children_omitted_outside_a_swarm
    seed

    refute parse(@collector.render).key?('wurk_swarm_children_expected')
  end

  def test_snapshot_is_cached_within_the_ttl
    seed
    first = parse(@collector.render)['wurk_processed_total'][{}]
    @redis.call('SET', 'stat:processed', '99')

    assert_equal first, parse(@collector.render)['wurk_processed_total'][{}], 'served from cache inside 1s'

    @now += Wurk::Metrics::Prometheus::TTL

    assert_in_delta(99.0, parse(@collector.render)['wurk_processed_total'][{}])
  end

  def test_label_values_are_escaped
    @redis.call('SADD', 'queues', "we\"ird\\q\nx")
    @redis.call('LPUSH', "queue:we\"ird\\q\nx", '{}')
    body = @collector.render

    assert_includes body, 'wurk_queue_size{queue="we\\"ird\\\\q\\nx"} 1'
    parse(body)
  end

  def test_unreachable_redis_reports_down_and_is_cached
    config = Wurk::Configuration.new
    config.redis = { url: 'redis://127.0.0.1:1/0', reconnect_attempts: 0, connect_timeout: 0.05 }
    config.logger = ::Logger.new(IO::NULL)
    collector = Wurk::Metrics::Prometheus.new(config, clock: -> { @now })
    families = parse(collector.render)

    assert_in_delta(0.0, families['wurk_redis_up'][{}])
    refute families.key?('wurk_queue_size')
    refute collector.snapshot.ok
  ensure
    config&.reset_redis_pools!
  end

  def test_unparseable_head_job_has_zero_latency
    @redis.call('SADD', 'queues', 'broken')
    @redis.call('LPUSH', 'queue:broken', 'not json')

    assert_in_delta(0.0, parse(@collector.render)['wurk_queue_latency_seconds'][{ 'queue' => 'broken' }])
  end

  def test_reports_consumers_per_queue_from_process_info
    @redis.call('SADD', Wurk::Keys::QUEUES_SET, 'watched', 'ghost')
    id = "#{HOST}:9:#{NONCE}"
    @redis.call('SADD', Wurk::Keys::PROCESSES, id)
    @redis.call('HSET', id, 'beat', ::Time.now.to_f.to_s, 'busy', '0', 'info', ::JSON.generate('queues' => %w[watched]))
    families = parse(@collector.render)

    assert_in_delta(1.0, families['wurk_queue_consumers'][{ 'queue' => 'watched' }])
    assert_in_delta(0.0, families['wurk_queue_consumers'][{ 'queue' => 'ghost' }])
  end

  def test_wurk_leader_reflects_whether_this_group_holds_the_lease
    assert_in_delta(0.0, parse(@collector.render)['wurk_leader'][{}])
    @redis.call('SET', Wurk::Leader::DEFAULT_KEY, "#{HOST}:9:#{NONCE}")
    @now += 2

    assert_in_delta(1.0, parse(@collector.render)['wurk_leader'][{}])
    @redis.call('DEL', Wurk::Leader::DEFAULT_KEY)
  end

  def test_exposes_the_process_local_counters
    before = Wurk::Metrics::ProcessCounters.value(:reaper_reclaimed)
    Wurk::Metrics::ProcessCounters.increment(:reaper_reclaimed, 3)
    Wurk::Metrics::ProcessCounters.increment(:fetch_errors)
    families = parse(@collector.render)

    assert_in_delta(before + 3.0, families['wurk_reaper_reclaimed_total'][{}])
    assert_operator families['wurk_fetch_errors_total'][{}], :>=, 1
  end

  def test_rtt_and_oldest_job_per_local_process
    seed
    now = Time.now.to_f
    @redis.call('HSET', "#{HOST}:101:#{NONCE}", 'rtt_us', '1500')
    work = Wurk.dump_json('queue' => 'default', 'payload' => '{"run_at":1}', 'run_at' => (now - 30).to_i)
    @redis.call('HSET', "#{HOST}:101:#{NONCE}:work", 't1', work)
    families = parse(@collector.render)

    assert_in_delta(0.0015, families['wurk_process_redis_rtt_seconds'][{ 'pid' => '101' }])
    assert_in_delta 30.0, families['wurk_process_oldest_job_seconds'][{ 'pid' => '101' }], 2.0
    assert_in_delta(0.0, families['wurk_process_oldest_job_seconds'][{ 'pid' => '102' }])
  end

  def test_pss_is_read_from_proc_for_a_live_local_pid
    skip 'no /proc smaps_rollup' unless File.readable?('/proc/self/smaps_rollup')

    process("#{HOST}:#{::Process.pid}:#{NONCE}", busy: 0, beat: Time.now.to_f)
    process("#{HOST}:999999999:#{NONCE}", busy: 0, beat: Time.now.to_f)
    pss = parse(@collector.render)['wurk_process_pss_bytes']

    assert_operator pss[{ 'pid' => ::Process.pid.to_s }], :>, 0
    refute pss.key?({ 'pid' => '999999999' }), 'an unreadable pid is left out, not reported as 0'
  end

  def test_swarm_restart_families_only_with_a_snapshot
    snap = Wurk::Swarm::RestartCounters::Snapshot.new({ crash: 2, recycle: 1, liveness: 0, rolling: 4 }, 3)
    families = parse(@collector.render(swarm: snap))

    assert_in_delta(2.0, families['wurk_swarm_child_restarts_total'][{ 'reason' => 'crash' }])
    assert_in_delta(4.0, families['wurk_swarm_child_restarts_total'][{ 'reason' => 'rolling' }])
    assert_in_delta(3.0, families['wurk_swarm_crash_streak'][{}])
    refute parse(@collector.render).key?('wurk_swarm_crash_streak')
  end

  def test_process_counter_families
    counters = Wurk::Metrics::ProcessCounters
    before = parse(@collector.render)
    counters.increment(:poison_kills)
    counters.increment(:leader_acquired)
    counters.increment(:client_buffer_drops, 2)
    counters.increment(:reaper_reclaimed, 5)
    counters.increment(:reaper_drained, 3)
    Wurk::Scheduled.record_promotions('schedule', 4)
    Wurk::Scheduled.record_promotions('retry', 0)
    after = parse(@collector.render)

    { 'wurk_poison_kills_total' => 1, 'wurk_leader_acquired_total' => 1,
      'wurk_client_buffer_dropped_total' => 2 }.each do |name, delta|
      assert_in_delta(before[name][{}] + delta, after[name][{}], 0.001, name)
    end
    reclaimed = %w[reaper self].map do |source|
      after['wurk_jobs_reclaimed_total'][{ 'source' => source }] -
        before['wurk_jobs_reclaimed_total'][{ 'source' => source }]
    end

    assert_equal [3.0, 2.0], reclaimed
    assert_in_delta(4.0, after['wurk_scheduler_promoted_total'][{ 'set' => 'schedule' }] -
                         before['wurk_scheduler_promoted_total'][{ 'set' => 'schedule' }])
  end

  def test_redis_pool_gauges_and_checkout_timeouts
    pool = Wurk::RedisPool.new(size: 2, name: 'prom-probe', url: Wurk::Test.redis_url, pool_timeout: 0.01)
    families = parse(@collector.render)

    assert_in_delta(2.0, families['wurk_redis_pool_size'][{ 'pool' => 'prom-probe' }])
    assert_in_delta(2.0, families['wurk_redis_pool_available'][{ 'pool' => 'prom-probe' }])
    before = families['wurk_redis_pool_checkout_timeouts_total'][{ 'pool' => 'prom-probe' }]
    starve(pool)
    families = parse(@collector.render)

    assert_in_delta(before + 2, families['wurk_redis_pool_checkout_timeouts_total'][{ 'pool' => 'prom-probe' }])
    pool.disconnect!

    refute parse(@collector.render)['wurk_redis_pool_size'].key?({ 'pool' => 'prom-probe' })
  end

  def test_job_duration_histogram_is_cumulative
    acc = Wurk::Metrics::History::ACCUMULATOR
    3.times { acc.add(nil, 'PromHistJob', 0, 25, true) }
    acc.drain
    families = parse(@collector.render)
    buckets = families['wurk_job_duration_seconds_bucket']

    assert_operator buckets[{ 'class' => 'PromHistJob', 'le' => '0.02' }], :<=,
                    buckets[{ 'class' => 'PromHistJob', 'le' => '0.03' }]
    assert_operator buckets[{ 'class' => 'PromHistJob', 'le' => '0.03' }], :>=, 3
    assert_equal buckets[{ 'class' => 'PromHistJob', 'le' => '+Inf' }],
                 families['wurk_job_duration_seconds_count'][{ 'class' => 'PromHistJob' }]
  end

  def test_duration_classes_past_the_cap_fold_into_other
    cap = Wurk::Metrics::ProcessFamilies::HISTOGRAM_CLASSES
    hist = Array.new(Wurk::Metrics::Histogram::SIZE, 0)
    lifetime = (0..(cap + 1)).to_h { |i| ["K#{i}", [100 - i, 1000, hist]] }
    kept = Wurk::Metrics::ProcessFamilies.send(:capped_durations, lifetime)

    assert_equal cap + 1, kept.size
    assert_equal (100 - cap) + (100 - cap - 1), kept['other'][0]
  end

  private

  def starve(pool)
    release = Queue.new
    holders = Array.new(pool.size) { Thread.new { pool.with { release.pop } } }
    sleep 0.01 until pool.available.zero?
    assert_raises(ConnectionPool::TimeoutError) { pool.with { nil } }
  ensure
    holders&.size&.times { release << true }
    holders&.each(&:join)
  end

  def seed
    now = Time.now.to_f
    @redis.call('SET', 'stat:processed', '42')
    @redis.call('SET', 'stat:failed', '7')
    @redis.call('SADD', 'queues', 'default', 'empty')
    old = Wurk.dump_json('class' => 'X', 'jid' => 'a', 'enqueued_at' => ((now - 120) * 1000).to_i)
    @redis.call('LPUSH', 'queue:default', old)
    @redis.call('LPUSH', 'queue:default', Wurk.dump_json('class' => 'X', 'jid' => 'b', 'enqueued_at' => now))
    @redis.call('ZADD', 'schedule', now + 60, '{}')
    @redis.call('ZADD', 'retry', now, '{"a":1}', now, '{"a":2}')
    @redis.call('ZADD', 'dead', now, '1', now, '2', now, '3')
    process("#{HOST}:101:#{NONCE}", busy: 2, beat: now - 1, rss: 2048)
    process("#{HOST}:102:#{NONCE}", busy: 1, beat: now - 100, quiet: true)
    process("other-host:7:#{NONCE}", busy: 3, beat: now)
    @redis.call('SADD', 'processes', "#{HOST}:103:#{NONCE}") # expired identity hash
  end

  def process(identity, busy:, beat:, rss: 1000, quiet: false)
    @redis.call('SADD', 'processes', identity)
    @redis.call('HSET', identity, 'busy', busy, 'concurrency', 10, 'beat', beat.to_s, 'rss', rss,
                'quiet', quiet.to_s)
  end

  # name => { labels Hash => Float }. Raises on any line the 0.0.4 grammar
  # rejects, on a sample with no preceding TYPE, or on a duplicate series.
  def parse(body)
    assert body.end_with?("\n"), 'exposition must end with a newline'
    families = {}
    typed = {}
    body.each_line(chomp: true) do |line|
      next parse_comment(line, typed) if line.start_with?('#')

      name, labels, value = parse_sample(line)

      assert typed.key?(name) || typed[name.sub(/_(?:bucket|sum|count)\z/, '')] == 'histogram',
             "sample #{name} has no TYPE line"
      series = (families[name] ||= {})

      refute series.key?(labels), "duplicate series #{line}"
      series[labels] = Float(value)
    end
    families
  end

  def parse_comment(line, typed)
    kind, name, rest = line.split(' ', 4).drop(1)

    assert_includes %w[HELP TYPE], kind, "bad comment #{line}"
    return unless kind == 'TYPE'

    assert_includes %w[counter gauge histogram], rest, "bad TYPE #{line}"
    typed[name] = rest
  end

  def parse_sample(line)
    match = METRIC_LINE.match(line)

    assert match, "not a valid sample line: #{line.inspect}"
    labels = {}
    split_labels(match[3].to_s).each do |pair|
      lm = LABEL_PAIR.match(pair)

      assert lm, "bad label pair #{pair.inspect} in #{line.inspect}"
      labels[lm[1]] = lm[2].gsub(/\\(.)/) { Regexp.last_match(1) == 'n' ? "\n" : Regexp.last_match(1) }
    end
    [match[1], labels, match[4]]
  end

  def split_labels(raw)
    raw.scan(/[a-zA-Z_][a-zA-Z0-9_]*="(?:[^"\\]|\\.)*"/)
  end
end
