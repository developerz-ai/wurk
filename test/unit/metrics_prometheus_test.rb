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

  private

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

      assert typed.key?(name), "sample #{name} has no TYPE line"
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

    assert_includes %w[counter gauge], rest, "bad TYPE #{line}"
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
