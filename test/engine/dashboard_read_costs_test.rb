# frozen_string_literal: true

require_relative '../engine_test_helper'
require_relative '../../bench/algo/support'

# What the dashboard's polled and paged reads cost Redis, and that collapsing
# them changed no byte the SPA reads (rows 21-K1..K5 and 07-A1/A2/A6/A14/A16 of
# docs/plans/2026/11/10/101-evidence-driven-improvement-sweep/). Round trips
# are counted by AlgoBench::Tally on a web pool built for the test; goldens
# are rendered from the public Sidekiq-surface readers (Stats, Queue, ProcessSet)
# the endpoints read through before, under a frozen wall clock so latencies
# match to the byte.
class DashboardReadCostsTest < Wurk::Test::EngineCase
  parallelize_me!

  NOW_MS = 1_800_000_000_000

  def setup
    super
    @pool = ::Wurk::RedisPool.new(size: 2, url: ::Wurk::Test.redis_url, middlewares: [AlgoBench::Tally])
    @pool.with { |c| ::Wurk::Test.flush!(c) }
    ::Wurk::SseStreaming::SHARED_TICK.clear!
    ::Wurk::Web::Enterprise::Limits.reset_probe!
  end

  def teardown
    @pool.with { |c| ::Wurk::Test.flush!(c) }
    @pool.disconnect!
    ::Wurk::SseStreaming::SHARED_TICK.clear!
    ::Wurk::Web::Enterprise::Limits.reset_probe!
  ensure
    super
  end

  # --- 21-K1, 07-A14: /api/stats and the SSE tick --------------------------

  def test_stats_payload_is_the_public_stats_payload_byte_for_byte
    seed_fleet

    expected = frozen_clock { ::JSON.generate(::Wurk::Api::Serializers.stats_payload(::Wurk::Stats.new)) }
    body = frozen_clock { tallied_get('/wurk/api/stats').first }

    assert_equal expected, body
  end

  def test_stats_costs_two_round_trips_whatever_the_fleet
    seed_fleet(queues: 20, processes: 10)
    _, cost = tallied_get('/wurk/api/stats')

    assert_equal 2, cost.round_trips, cost.inspect
    assert_equal({ 'llen' => 20, 'hget' => 10 }, cost.by_command.slice('llen', 'hget'))
  end

  # Three streams ticking inside one second read Redis once between them.
  def test_concurrent_stream_ticks_share_one_read
    seed_fleet
    @pool.with { |c| c.call('PING') }
    cost = AlgoBench.count do
      with_tallied_web_pool { 3.times { get '/wurk/api/stream?max_duration=0&tick=0' } }
    end

    assert_equal 2, cost.round_trips
    assert_includes last_response.body, 'event: stats'
  end

  # --- 21-K2: /api/queues ---------------------------------------------------

  def test_queues_payload_is_unchanged_and_costs_two_round_trips
    seed_fleet

    expected = frozen_clock do
      consumers = ::Wurk.redis { |conn| ::Wurk::QueueConsumers.counts(conn) }
      ::JSON.generate(::Wurk::Stats.new.queue_summaries.map do |q|
        ::Wurk::Api::Serializers.queue_summary(q).merge(consumers: consumers.fetch(q.name, 0))
      end)
    end
    body, cost = frozen_clock { tallied_get('/wurk/api/queues') }

    assert_equal expected, body
    assert_equal 2, cost.round_trips
  end

  # --- 21-K3, 07-A1: queue detail -------------------------------------------

  def test_queue_detail_is_unchanged_and_one_round_trip_at_any_depth
    seed_queue('deep', 60)
    queue = ::Wurk::Queue.new('deep')
    [0, 2].each do |page|
      expected = frozen_clock do
        jobs = queue.to_a[page * 25, 25].map { |rec| ::Wurk::Api::Serializers.job_record(rec) }
        ::JSON.generate(name: 'deep', size: queue.size, latency: queue.latency, paused: queue.paused?,
                        page: page, count: 25, max_page: ::Wurk::Api::Pagination::MAX_PAGE, jobs: jobs)
      end
      body, cost = frozen_clock { tallied_get("/wurk/api/queues/deep?page=#{page}") }

      assert_equal expected, body, "page #{page}"
      assert_equal 1, cost.round_trips, "page #{page}"
    end
  end

  # --- 07-A1, A16: sorted sets ------------------------------------------------

  def test_dead_listing_pages_in_one_round_trip_without_backtraces
    keys = seed_dead(60)
    first, first_cost = tallied_get('/wurk/api/dead?page=0')
    deep, deep_cost = tallied_get('/wurk/api/dead?page=2')

    assert_equal [1, 1], [first_cost.round_trips, deep_cost.round_trips]
    assert_equal(keys.reverse.first(25), parse(first)[:entries].map { |row| "#{row[:score]}|#{row[:jid]}" })
    assert_equal(keys.reverse[50, 10], parse(deep)[:entries].map { |row| "#{row[:score]}|#{row[:jid]}" })
    refute(parse(first)[:entries].any? { |row| row.key?(:error_backtrace) })
  end

  # The detail endpoint answers the row the listing used to serve, backtrace
  # last, as the SPA's modal read it.
  def test_dead_entry_detail_carries_the_backtrace
    key = seed_dead(1).first
    entry = ::Wurk::DeadSet.new.first
    get "/wurk/api/dead/#{CGI.escape(key)}"

    assert_equal 200, last_response.status
    row = parse(last_response.body)

    assert_equal ["app/jobs/a.rb:1:in 'perform'"], row[:error_backtrace]
    assert_equal %i[jid klass args queue enqueued_at created_at score at error_class error_message retry_count
                    error_backtrace], row.keys
    assert_equal entry.score, row[:score]
  end

  def test_entry_detail_is_404_once_the_entry_is_gone
    get "/wurk/api/retries/#{CGI.escape('1700000000.0|nope')}"

    assert_equal 404, last_response.status
  end

  # --- 07-A1, A2: batches and flows -------------------------------------------

  def test_batch_rows_count_jids_rather_than_list_them
    seed_batches(30)
    ::Wurk.redis { |c| c.call('SADD', 'b-b0029-failed', 'j1', 'j2') }
    body, cost = tallied_get('/wurk/api/batches?page=0')
    _, deep_cost = tallied_get('/wurk/api/batches?page=1')
    row = parse(body)[:batches].first
    data = ::Wurk::Batch::Status.new('b0029').data.transform_keys(&:to_sym)

    assert_equal [2, 2], [cost.round_trips, deep_cost.round_trips]
    assert_equal 2, row[:failed_count]
    assert_equal 0, row[:dead_count]
    refute row.key?(:failed_jids)
    refute row.key?(:dead_jids)
    assert_equal data.except(:failed_jids, :dead_jids), row.except(:failed_count, :dead_count)
  end

  def test_flow_rows_are_unchanged_and_two_round_trips_at_any_depth
    seed_flows(30)
    expected = ::Wurk::FlowSet.new.to_a[25, 5].map { |status| ::Wurk::Api::Serializers.flow_row(status) }
    body, cost = tallied_get('/wurk/api/flows?page=1')

    assert_equal 2, cost.round_trips
    assert_equal ::JSON.parse(::JSON.generate(expected)), ::JSON.parse(body)['flows']
  end

  # --- 21-K5: processes ------------------------------------------------------

  # Steady state, the prune not due: the prune lock's SET NX, SMEMBERS, then
  # the HMGETs with `GET dear-leader` riding along (it was a fourth trip).
  def test_processes_leader_flag_rides_the_heartbeat_pipeline
    seed_fleet(processes: 3)
    ::Wurk.redis { |c| c.call('SET', 'process_cleanup', '1', 'EX', '60') }
    body, cost = tallied_get('/wurk/api/processes')

    assert_equal 3, cost.round_trips
    assert_equal(['host0:1000:nonce0'], parse(body).select { |row| row[:leader] }.map { |row| row[:identity] })
  end

  # --- 07-A6: limits ----------------------------------------------------------

  def test_limits_probe_liveness_once_not_per_page
    names = Array.new(3) { |i| "lmt-cost-#{i}" }
    ::Wurk.redis do |c|
      names.each do |name|
        c.call('SADD', ::Wurk::Limiter::LIST_KEY, name)
        c.call('HSET', "lmtr:#{name}", 'type', 'concurrent', 'fingerprint', 'fp', 'options', '{"limit":5}')
      end
    end
    _, cold = tallied_get('/wurk/api/limiters?page=0&count=2')
    body, warm = tallied_get('/wurk/api/limiters?page=1&count=2')

    assert_equal 3, cold.by_command['exists']
    assert_nil warm.by_command['exists']
    assert_equal(['lmt-cost-2'], parse(body)[:limiters].map { |row| row[:name] })
    assert_equal 3, parse(body)[:total]
  end

  private

  def parse(body) = ::JSON.parse(body, symbolize_names: true)

  # [body, AlgoBench::Count] of a GET served from the tallied web pool.
  def tallied_get(path)
    body = nil
    @pool.with { |c| c.call('PING') } # the connection prelude is not the endpoint's
    cost = AlgoBench.count do
      with_tallied_web_pool { get path }

      assert_equal 200, last_response.status, last_response.body[0, 300]
      body = last_response.body
    end
    [body, cost]
  end

  def with_tallied_web_pool
    pool = @pool
    config = ::Wurk.configuration
    config.define_singleton_method(:web_redis_pool) { pool }
    yield
  ensure
    config.singleton_class.remove_method(:web_redis_pool)
  end

  def frozen_clock
    original = ::Process.method(:clock_gettime)
    ::Process.define_singleton_method(:clock_gettime) do |clock, *unit|
      clock == ::Process::CLOCK_REALTIME && unit == [:millisecond] ? NOW_MS : original.call(clock, *unit)
    end
    yield
  ensure
    ::Process.define_singleton_method(:clock_gettime, original)
  end

  def job(index, queue, enqueued_at: 1_799_999_000.0 + index)
    { 'class' => 'CostJob', 'args' => [index], 'queue' => queue, 'jid' => format('%024x', index),
      'created_at' => 1_700_000_000.0, 'enqueued_at' => enqueued_at, 'retry' => true }
  end

  def seed_queue(name, size)
    ::Wurk.redis do |c|
      c.call('SADD', 'queues', name)
      size.times { |i| c.call('LPUSH', "queue:#{name}", ::JSON.generate(job(i, name))) }
    end
  end

  # Distinct sizes, so the size-descending order has no ties to break; one of
  # them `default`, one paused, processes subscribing to a subset.
  def seed_fleet(queues: 4, processes: 2)
    names = Array.new(queues) { |q| q.zero? ? 'default' : "q#{q}" }
    names.each_with_index { |name, i| seed_queue(name, i + 1) }
    ::Wurk.redis do |c|
      c.call('SADD', 'paused', names.last)
      processes.times do |p|
        identity = "host#{p}:#{1000 + p}:nonce#{p}"
        info = { 'hostname' => "host#{p}", 'pid' => 1000 + p, 'identity' => identity, 'concurrency' => 5,
                 'queues' => names.first(p + 1), 'labels' => [], 'started_at' => 1_799_000_000.0 }
        c.call('SADD', 'processes', identity)
        c.call('HSET', identity, 'info', ::JSON.generate(info), 'concurrency', '5', 'busy', (p + 1).to_s,
               'beat', '1799999999.0', 'quiet', 'false', 'rss', '1000', 'rtt_us', '100')
      end
      c.call('SET', 'dear-leader', 'host0:1000:nonce0')
    end
  end

  def seed_dead(count)
    backtrace = [::Zlib::Deflate.deflate(::JSON.generate(["app/jobs/a.rb:1:in 'perform'"]))].pack('m0')
    Array.new(count) do |i|
      score = 1_700_000_000.0 + i
      payload = job(i, 'dead-q').merge('error_class' => 'RuntimeError', 'error_message' => 'boom',
                                       'retry_count' => 25, 'error_backtrace' => backtrace)
      ::Wurk.redis { |c| c.call('ZADD', 'dead', score, ::JSON.generate(payload)) }
      "#{score}|#{payload['jid']}"
    end
  end

  def seed_batches(count)
    ::Wurk.redis do |c|
      count.times do |i|
        bid = format('b%04d', i)
        c.call('ZADD', 'batches', i, bid)
        c.call('HSET', "b-#{bid}", 'total', '10', 'pending', '2', 'failures', '1', 'created_at', '1700000000.0',
               'description', "batch #{i}")
      end
    end
  end

  def seed_flows(count)
    ::Wurk.redis do |c|
      count.times do |i|
        fid = format('f%04d', i)
        c.call('ZADD', ::Wurk::Keys::FLOWS_SET, i, fid)
        c.call('HSET', ::Wurk::Keys.flow(fid), 'state', 'running', 'total', '4', 'pending', '2', 'depth', '2',
               'width', '2', 'created_at', '1700000000.0')
      end
    end
  end
end
