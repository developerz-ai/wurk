# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'json'
require 'securerandom'
require 'stringio'

# Slice 07 — the HTTP API's swarm plane: GET /swarm, /processes,
# /processes/:identity, /busy, /health, /limiters, /cron and the two process
# signals.
#
# The plane's contract is that watching the swarm costs the swarm nothing: no
# new Redis key, no new heartbeat field, no extra beat. So the fixtures below
# write the heartbeat HASHes exactly as Wurk::Heartbeat#write_beat does and the
# assertions check that the HTTP answer is the one ProcessSet, WorkSet,
# Cron::LoopSet and the limiter registry give for the same bytes.
#
# Auth mechanics live in api_auth_test.rb and routing in api_app_test.rb; the
# scope checks here only pin which scope each route demands.
#
# Isolation: each test runs against a freshly flushed worker DB
# (RedisNamespace), and identities still carry a per-instance namespace so a
# fixture reads the way production data would.
class ApiSwarmTest < Wurk::Test::UnitCase
  parallelize_me!

  ADMIN_TOKEN = 'api-swarm-admin-token-0123456789'
  READ_TOKEN = 'api-swarm-read-token-0123456789'
  ENQUEUE_TOKEN = 'api-swarm-enqueue-token-0123456789'

  READ_ROUTES = %w[/v1/swarm /v1/processes /v1/busy /v1/health /v1/limiters /v1/cron].freeze

  def setup
    super
    @ns = "#{Process.pid}-#{object_id}"
    @pool = Wurk.configuration.redis_pool
    @now = Time.now.to_f
  end

  # --- GET /swarm --------------------------------------------------------

  def test_swarm_rolls_up_the_live_processes
    beat('a', concurrency: 10, busy: 3, rss: 120_000)
    beat('b', concurrency: 6, busy: 0, rss: 90_000)

    status, headers, body = get('/v1/swarm')

    assert_equal 200, status
    assert_equal 'application/json', headers['content-type']
    assert_equal({ 'total' => 2, 'quiet' => 0, 'stale' => 0 }, body['processes'])
    assert_equal 16, body['concurrency']
    assert_equal 3, body['busy']
    assert_in_delta 0.1875, body['utilization'], 0.0001
    assert_equal 210_000, body['rss_kb']
  end

  def test_swarm_reports_the_union_of_queues_and_versions
    beat('a', queues: %w[critical default], version: '1.2.3')
    beat('b', queues: %w[default bulk], version: '1.2.4')

    _status, _headers, body = get('/v1/swarm')

    assert_equal %w[bulk critical default], body['queues']
    assert_equal %w[1.2.3 1.2.4], body['versions']
  end

  # Nothing running is 0% busy, not a division by zero and not a null the
  # client has to special-case.
  def test_swarm_utilization_is_zero_for_an_empty_fleet
    _status, _headers, body = get('/v1/swarm')

    assert_equal({ 'total' => 0, 'quiet' => 0, 'stale' => 0 }, body['processes'])
    assert_in_delta 0.0, body['utilization'], 0.0001
    assert_nil body['beat']['oldest_age_seconds']
  end

  def test_swarm_counts_quiet_and_stale_processes
    beat('live')
    beat('draining', quiet: true)
    beat('gone', beat_at: @now - 120)

    _status, _headers, body = get('/v1/swarm')

    assert_equal({ 'total' => 3, 'quiet' => 1, 'stale' => 1 }, body['processes'])
  end

  # The threshold rides along with the verdict, so a client reads the rule and
  # the reading it produced in the same document.
  def test_swarm_ships_the_staleness_threshold_with_the_oldest_beat
    beat('a', beat_at: @now - 45)

    _status, _headers, body = get('/v1/swarm')

    assert_equal 30, body['beat']['stale_after_seconds']
    assert_in_delta 45.0, body['beat']['oldest_age_seconds'], 1.0
  end

  def test_swarm_names_the_leader_and_whether_it_is_live
    identity = beat('a')
    beat('b')
    @pool.with { |c| c.call('SET', 'dear-leader', identity) }

    _status, _headers, body = get('/v1/swarm')

    assert_equal identity, body['leader']['identity']
    assert body['leader']['live']
  end

  # `dear-leader` outlives the heartbeat that took it, so between the two
  # expiries the cluster has a recorded leader and no leader — a state the
  # roll-up has to be able to say out loud.
  def test_swarm_reports_an_orphaned_leader_lock_as_not_live
    beat('a')
    @pool.with { |c| c.call('SET', 'dear-leader', "gone-#{@ns}:1:x") }

    _status, _headers, body = get('/v1/swarm')

    assert_equal "gone-#{@ns}:1:x", body['leader']['identity']
    refute body['leader']['live']
  end

  def test_swarm_reports_no_leader_when_the_lock_is_unset
    beat('a')

    _status, _headers, body = get('/v1/swarm')

    assert_nil body['leader']['identity']
    refute body['leader']['live']
  end

  def test_swarm_groups_processes_by_host
    beat('a', hostname: 'box-a', concurrency: 4, busy: 1, rss: 100)
    beat('b', hostname: 'box-a', concurrency: 4, busy: 2, rss: 200)
    beat('c', hostname: 'box-b', concurrency: 8, busy: 0, rss: 300)

    _status, _headers, body = get('/v1/swarm')
    first, second = body['hosts']

    assert_equal(%w[box-a box-b], body['hosts'].map { |host| host['hostname'] })
    assert_equal 2, first['processes']
    assert_equal 8, first['concurrency']
    assert_equal 3, first['busy']
    assert_equal 300, first['rss_kb']
    assert_equal 1, second['processes']
  end

  # Host hardware facts belong to the box, so they ride the host roll-up once
  # rather than repeating on every child the box is running.
  def test_swarm_reports_host_hardware_once_per_host
    beat('a', hostname: 'box-a')
    beat('b', hostname: 'box-a')

    _status, _headers, body = get('/v1/swarm')
    host = body['hosts'].fetch(0)

    assert_equal 'Fake CPU', host['cpu_model']
    assert_equal 8, host['cores']
    assert_equal 16_000_000, host['memory_total_kb']
  end

  # The slot table is the one the heartbeats describe, not the one this
  # process's own configuration declares: a standalone `wurk api` shares no
  # config with the swarm parent and would otherwise report a topology derived
  # from its own CPU count.
  def test_swarm_reports_the_slot_shape_the_heartbeats_describe
    beat('a', queues: %w[critical default], concurrency: 5)
    beat('b', queues: %w[default critical], concurrency: 5)
    beat('c', queues: %w[bulk], concurrency: 2)

    _status, _headers, body = get('/v1/swarm')

    assert_equal(
      [{ 'count' => 2, 'queues' => %w[critical default], 'concurrency' => 5 },
       { 'count' => 1, 'queues' => %w[bulk], 'concurrency' => 2 }],
      body['slots']
    )
  end

  # An identity whose heartbeat HASH expired is still in the `processes` SET
  # until something prunes it, and this plane deliberately never prunes.
  def test_swarm_skips_identities_whose_heartbeat_expired
    beat('a')
    @pool.with { |c| c.call('SADD', 'processes', "ghost-#{@ns}:1:x") }

    _status, _headers, body = get('/v1/swarm')

    assert_equal 1, body['processes']['total']
  end

  # The sweep is a Redis write behind a Redis write; a monitor polling this
  # plane must not pay either.
  def test_swarm_does_not_run_the_process_sweep
    beat('a')
    get('/v1/swarm')

    assert_nil(@pool.with { |c| c.call('GET', 'process_cleanup') })
  end

  # --- GET /processes ----------------------------------------------------

  def test_processes_lists_what_each_process_declared_about_itself
    identity = beat('a', hostname: 'box-a', pid: 4321, tag: 'web', concurrency: 10,
                         queues: %w[critical default], version: '9.9.9')

    status, _headers, body = get('/v1/processes')
    row = body['processes'].fetch(0)

    assert_equal 200, status
    assert_equal 1, body['total']
    assert_equal identity, row['identity']
    assert_equal 'box-a', row['hostname']
    assert_equal 4321, row['pid']
    assert_equal 'web', row['tag']
    assert_equal 10, row['concurrency']
    assert_equal %w[critical default], row['queues']
    assert_equal({ 'critical' => 2, 'default' => 1 }, row['weights'])
    assert_equal '9.9.9', row['version']
    refute row['embedded']
  end

  def test_processes_reports_what_the_last_beat_measured
    beat('a', busy: 4, rss: 123_456, rtt_us: 900, quiet: true)

    _status, _headers, body = get('/v1/processes')
    row = body['processes'].fetch(0)

    assert_equal 4, row['busy']
    assert_equal 123_456, row['rss_kb']
    assert_equal 900, row['rtt_us']
    assert row['quiet']
  end

  # Derived here so a client never has to compare the swarm's clock against
  # its own — the one comparison this plane exists to save it from.
  def test_processes_derive_beat_age_uptime_and_staleness
    beat('fresh', beat_at: @now - 2, started_at: @now - 600)
    beat('stale', beat_at: @now - 90, started_at: @now - 900)

    _status, _headers, body = get('/v1/processes')
    fresh = row_for(body['processes'], 'fresh')
    stale = row_for(body['processes'], 'stale')

    assert_in_delta 2.0, fresh['beat_age_seconds'], 1.0
    assert_in_delta 600.0, fresh['uptime_seconds'], 1.0
    refute fresh['stale']
    assert_in_delta 90.0, stale['beat_age_seconds'], 1.0
    assert stale['stale']
  end

  # `beat` is stamped by the beating process's clock and read on another's, so
  # a skew of a few milliseconds must not surface as a negative age.
  def test_processes_never_report_a_negative_beat_age
    beat('a', beat_at: @now + 5)

    _status, _headers, body = get('/v1/processes')

    assert_in_delta 0.0, body['processes'].fetch(0)['beat_age_seconds'], 0.0001
  end

  # A heartbeat written before `started_at` existed reports a null uptime: a
  # process of unknown age is not one that just booted.
  def test_processes_report_a_null_uptime_when_the_beat_carries_no_start
    identity = beat('a')
    @pool.with do |c|
      info = Wurk.load_json(c.call('HGET', identity, 'info'))
      c.call('HSET', identity, 'info', Wurk.dump_json(info.reject { |key, _| key == 'started_at' }))
    end

    _status, _headers, body = get('/v1/processes')

    assert_nil body['processes'].fetch(0)['started_at']
    assert_nil body['processes'].fetch(0)['uptime_seconds']
  end

  def test_processes_flag_the_leader
    identity = beat('a')
    beat('b')
    @pool.with { |c| c.call('SET', 'dear-leader', identity) }

    _status, _headers, body = get('/v1/processes')

    assert_equal([identity], body['processes'].select { |row| row['leader'] }.map { |row| row['identity'] })
  end

  def test_processes_count_only_the_live_ones
    beat('a')
    @pool.with { |c| c.call('SADD', 'processes', "ghost-#{@ns}:1:x") }

    _status, _headers, body = get('/v1/processes')

    assert_equal 1, body['total']
    assert_equal 1, body['processes'].size
  end

  def test_processes_page_and_echo_the_effective_window
    3.times { |i| beat("p#{i}") }

    _status, _headers, body = get('/v1/processes?page=1&count=2')

    assert_equal 3, body['total']
    assert_equal 1, body['page']
    assert_equal 2, body['count']
    assert_equal 1, body['processes'].size
  end

  def test_processes_refuse_a_malformed_paging_parameter
    status, _headers, body = get('/v1/processes?count=all')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  # --- GET /processes/:identity ------------------------------------------

  def test_process_detail_returns_the_listing_row_plus_its_work
    identity = beat('a')
    work(identity, jid: 'abc123def4567890abcdef01', queue: 'critical', run_at: @now - 5)

    status, _headers, body = get("/v1/processes/#{identity}")

    assert_equal 200, status
    assert_equal identity, body['process']['identity']
    assert_equal 1, body['work'].size
    entry = body['work'].fetch(0)

    assert_equal 'abc123def4567890abcdef01', entry['jid']
    assert_equal 'critical', entry['queue']
    assert_in_delta 5.0, entry['elapsed_seconds'], 1.0
  end

  # A client that read a row out of the listing and then fetched it should not
  # have to reshape anything.
  def test_process_detail_row_has_the_same_shape_as_the_listing_row
    identity = beat('a')

    _status, _headers, listing = get('/v1/processes')
    _status, _headers, detail = get("/v1/processes/#{identity}")

    assert_equal listing['processes'].fetch(0).keys.sort, detail['process'].keys.sort
  end

  def test_process_detail_shows_only_that_process_work
    first = beat('a')
    second = beat('b')
    work(first, jid: 'aaaaaaaaaaaaaaaaaaaaaaaa')
    work(second, jid: 'bbbbbbbbbbbbbbbbbbbbbbbb')

    _status, _headers, body = get("/v1/processes/#{first}")

    assert_equal(%w[aaaaaaaaaaaaaaaaaaaaaaaa], body['work'].map { |entry| entry['jid'] })
  end

  def test_process_detail_of_an_unknown_identity_is_a_process_not_found_problem
    status, headers, body = get("/v1/processes/nobody-#{@ns}:1:x")

    assert_equal 404, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'process_not_found', body['type']
    assert_equal 'Process Not Found', body['title']
    assert_equal "nobody-#{@ns}:1:x", body['identity']
  end

  def test_process_detail_rejects_a_malformed_identity
    status, _headers, body = get('/v1/processes/two%20words')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_includes body['detail'], 'process identity'
  end

  # --- POST /processes/:identity/quiet|stop ------------------------------

  def test_quiet_queues_a_tstp_on_the_targets_signal_list
    identity = beat('a')

    status, _headers, body = post("/v1/processes/#{identity}/quiet")

    assert_equal 200, status
    assert_equal 'TSTP', body['signal']
    assert_equal [identity], body['signalled']
    assert_empty body['skipped']
    assert_equal %w[TSTP], signals(identity)
  end

  def test_stop_queues_a_term_on_the_targets_signal_list
    identity = beat('a')

    _status, _headers, body = post("/v1/processes/#{identity}/stop")

    assert_equal 'TERM', body['signal']
    assert_equal %w[TERM], signals(identity)
  end

  def test_signalling_all_broadcasts_to_every_live_process
    first = beat('a')
    second = beat('b')

    _status, _headers, body = post('/v1/processes/all/quiet')

    assert_equal [first, second].sort, body['signalled'].sort
    assert_equal %w[TSTP], signals(first)
    assert_equal %w[TSTP], signals(second)
  end

  # One member that cannot be signalled is no reason to refuse the fleet.
  def test_broadcast_skips_an_embedded_process
    normal = beat('a')
    embedded = beat('b', embedded: true)

    _status, _headers, body = post('/v1/processes/all/stop')

    assert_equal [normal], body['signalled']
    assert_equal [embedded], body['skipped']
    assert_empty signals(embedded)
  end

  # Addressed directly, though, the caller asked about that process and gets a
  # verdict about it: 409, because the request is well-formed and permitted
  # and only the target's state refuses it.
  def test_signalling_an_embedded_process_is_a_conflict
    identity = beat('a', embedded: true)

    status, headers, body = post("/v1/processes/#{identity}/quiet")

    assert_equal 409, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'process_not_signalable', body['type']
    assert_equal identity, body['identity']
    assert_empty signals(identity)
  end

  def test_signalling_an_unknown_process_is_a_process_not_found_problem
    status, _headers, body = post("/v1/processes/nobody-#{@ns}:1:x/quiet")

    assert_equal 404, status
    assert_equal 'process_not_found', body['type']
  end

  def test_signalling_rejects_a_malformed_identity
    status, _headers, body = post('/v1/processes/two%20words/stop')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  # --- GET /busy ---------------------------------------------------------

  def test_busy_lists_the_in_flight_jobs_cluster_wide
    first = beat('a')
    second = beat('b')
    work(first, jid: 'aaaaaaaaaaaaaaaaaaaaaaaa', run_at: @now - 30)
    work(second, jid: 'bbbbbbbbbbbbbbbbbbbbbbbb', run_at: @now - 5)

    status, _headers, body = get('/v1/busy')

    assert_equal 200, status
    assert_equal 2, body['total']
    # WorkSet orders oldest first so the job most likely to be stuck leads.
    assert_equal(%w[aaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbb], body['jobs'].map { |job| job['jid'] })
    assert_equal first, body['jobs'].fetch(0)['process_id']
    assert_in_delta 30.0, body['jobs'].fetch(0)['elapsed_seconds'], 1.0
  end

  def test_busy_pages
    identity = beat('a')
    3.times { |i| work(identity, jid: format('%024d', i), thread_id: "t#{i}", run_at: @now - i) }

    _status, _headers, body = get('/v1/busy?count=2')

    assert_equal 3, body['total']
    assert_equal 2, body['jobs'].size
  end

  # The display view, exactly as the queue listings serve it: publishing
  # `payload['args']` here would put every encrypted job's envelope on the wire.
  def test_busy_masks_an_encrypted_jobs_arguments
    identity = beat('a')
    work(identity, jid: 'cccccccccccccccccccccccc', payload_overrides: { 'encrypt' => true })

    _status, _headers, body = get('/v1/busy')

    refute_includes body['jobs'].fetch(0)['args'].inspect, 'secret-value'
  end

  # --- GET /health -------------------------------------------------------

  def test_health_is_ok_when_redis_answers_and_something_is_beating
    beat('a')

    status, _headers, body = get('/v1/health')

    assert_equal 200, status
    assert_equal 'ok', body['status']
    assert body['redis']['ok']
    assert_operator body['redis']['rtt_ms'], :>=, 0
    assert_equal({ 'total' => 1, 'live' => 1, 'stale' => 0, 'quiet' => 0 }, body['processes'])
    assert_equal 30, body['stale_after_seconds']
  end

  def test_health_is_down_when_nothing_is_beating
    status, _headers, body = get('/v1/health')

    assert_equal 503, status
    assert_equal 'down', body['status']
    assert_equal 'no live processes', body['reason']
    assert body['redis']['ok']
  end

  def test_health_is_down_when_every_beat_is_stale
    beat('a', beat_at: @now - 120)

    status, _headers, body = get('/v1/health')

    assert_equal 503, status
    assert_equal 'no live processes', body['reason']
    assert_equal({ 'total' => 1, 'live' => 0, 'stale' => 1, 'quiet' => 0 }, body['processes'])
  end

  # A draining process is still finishing work, and Wurk::Health does not fail
  # readiness for one either — so `quiet` is reported, not folded into the
  # verdict.
  def test_health_reports_quiet_processes_without_failing_on_them
    beat('a', quiet: true)

    status, _headers, body = get('/v1/health')

    assert_equal 200, status
    assert_equal 1, body['processes']['quiet']
  end

  # Not a stub: a real RedisPool dialing a closed port, installed through the
  # per-thread capsule override Wurk.redis_pool already honours, so no sibling
  # test's connection is touched.
  def test_health_is_down_when_redis_is_unreachable
    status, _headers, body = with_unreachable_redis { get('/v1/health') }

    assert_equal 503, status
    assert_equal 'down', body['status']
    assert_equal 'redis unreachable', body['reason']
    refute body['redis']['ok']
    assert_nil body['redis']['rtt_ms']
    assert_nil body['processes']
  end

  # --- GET /limiters -----------------------------------------------------

  def test_limiters_lists_the_registry_with_each_limiters_status
    name = "lim-#{@ns}"
    Wurk::Limiter.concurrent(name, 5)

    status, _headers, body = get('/v1/limiters')
    row = body['limiters'].fetch(0)

    assert_equal 200, status
    assert_equal 1, body['total']
    assert_equal name, row['name']
    assert_equal 'concurrent', row['type']
    refute_empty row['fingerprint']
    assert_equal 5, row['options']['limit']
    assert_equal 0, row['status']['used']
    assert_equal 5, row['status']['limit']
    assert row['status']['available']
  end

  # `available?` is Ruby's spelling of a predicate, not JSON's.
  def test_limiter_status_uses_a_json_shaped_boolean_key
    Wurk::Limiter.concurrent("lim-#{@ns}", 1)

    _status, _headers, body = get('/v1/limiters')

    refute body['limiters'].fetch(0)['status'].key?('available?')
  end

  # Metadata a limiter type can no longer be rebuilt from yields a null status
  # rather than a 500 for the whole page — the dashboard's Limits tab is
  # best-effort for the same reason.
  def test_limiter_status_is_null_when_the_type_cannot_be_rebuilt
    name = "lim-#{@ns}"
    @pool.with do |c|
      c.call('HSET', "lmtr:#{name}", 'type', 'from-the-future', 'options', '{}')
      c.call('SADD', 'lmtr-list', name)
    end

    _status, _headers, body = get('/v1/limiters')

    assert_equal 'from-the-future', body['limiters'].fetch(0)['type']
    assert_nil body['limiters'].fetch(0)['status']
  end

  # The other half of the same refusal: a known type whose persisted options
  # no longer satisfy its constructor (a bucket with no interval).
  def test_limiter_status_is_null_when_the_options_no_longer_build
    name = "lim-#{@ns}"
    @pool.with do |c|
      c.call('HSET', "lmtr:#{name}", 'type', 'bucket', 'options', '{}')
      c.call('SADD', 'lmtr-list', name)
    end

    _status, _headers, body = get('/v1/limiters')

    assert_equal 'bucket', body['limiters'].fetch(0)['type']
    assert_nil body['limiters'].fetch(0)['status']
  end

  # Options the registry can no longer parse are an empty object, not a 500
  # and not the raw string — the row's other fields are still worth serving.
  def test_limiter_options_survive_unreadable_metadata
    @pool.with do |c|
      c.call('HSET', "lmtr:a-unparseable-#{@ns}", 'type', 'concurrent', 'options', '{not json')
      c.call('HSET', "lmtr:b-optionless-#{@ns}", 'type', 'concurrent')
      c.call('SADD', 'lmtr-list', "a-unparseable-#{@ns}", "b-optionless-#{@ns}")
    end

    _status, _headers, body = get('/v1/limiters')

    assert_equal [{}, {}], body['limiters'].map { |row| row['options'] }
  end

  def test_limiters_filter_by_substring
    Wurk::Limiter.concurrent("stripe-#{@ns}", 1)
    Wurk::Limiter.concurrent("mailer-#{@ns}", 1)

    _status, _headers, body = get('/v1/limiters?filter=STRIPE')

    assert_equal 1, body['total']
    assert_equal "stripe-#{@ns}", body['limiters'].fetch(0)['name']
  end

  def test_limiters_refuse_an_oversized_filter
    status, _headers, body = get("/v1/limiters?filter=#{'x' * 256}")

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_includes body['detail'], "'filter'"
  end

  def test_limiters_refuse_a_repeated_filter
    status, _headers, body = get('/v1/limiters?filter=a&filter=b')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  def test_limiters_page
    3.times { |i| Wurk::Limiter.concurrent("lim#{i}-#{@ns}", 1) }

    _status, _headers, body = get('/v1/limiters?count=2')

    assert_equal 3, body['total']
    assert_equal 2, body['limiters'].size
  end

  # --- GET /cron ---------------------------------------------------------

  def test_cron_lists_the_registered_loops
    loop_obj = register_cron('*/5 * * * *', queue: 'critical', args: [1, 'two'])

    status, _headers, body = get('/v1/cron')
    row = body['cron'].fetch(0)

    assert_equal 200, status
    assert_equal 1, body['total']
    assert_equal loop_obj.lid, row['lid']
    assert_equal '*/5 * * * *', row['schedule']
    assert_equal loop_obj.klass, row['class']
    assert_equal 'critical', row['queue']
    assert_equal [1, 'two'], row['args']
    refute row['paused']
    assert_nil row['last_fired_at']
    assert_operator row['next_fire_at'], :>, Time.now.to_i - 1
  end

  def test_cron_reports_the_last_fire_the_poller_recorded
    loop_obj = register_cron('*/5 * * * *')
    fired_at = Time.now.to_i - 300
    key = "#{Wurk::Cron::HISTORY_PREFIX}#{loop_obj.lid}"
    @pool.with { |c| c.call('LPUSH', key, Wurk.dump_json([fired_at, 'abc'])) }

    _status, _headers, body = get('/v1/cron')

    assert_equal fired_at, body['cron'].fetch(0)['last_fired_at']
  end

  def test_cron_pages
    3.times { |i| register_cron("#{i} * * * *") }

    _status, _headers, body = get('/v1/cron?count=2')

    assert_equal 3, body['total']
    assert_equal 2, body['cron'].size
  end

  # --- scopes ------------------------------------------------------------

  def test_read_scope_may_observe
    beat('a')
    READ_ROUTES.each do |path|
      status, = get(path, token: READ_TOKEN)

      assert_equal 200, status, path
    end
  end

  def test_enqueue_scope_may_not_observe
    status, _headers, body = get('/v1/swarm', token: ENQUEUE_TOKEN)

    assert_equal 403, status
    assert_equal 'insufficient_scope', body['type']
    assert_equal 'read', body['required_scope']
  end

  # Quieting the fleet stops it working without enqueueing or deleting
  # anything, so both signals sit with the destructive routes.
  def test_read_scope_may_not_signal
    identity = beat('a')

    %w[quiet stop].each do |action|
      status, _headers, body = post("/v1/processes/#{identity}/#{action}", token: READ_TOKEN)

      assert_equal 403, status, action
      assert_equal 'admin', body['required_scope']
    end
    assert_empty signals(identity)
  end

  private

  def app = @app ||= Wurk::API::App.new(config: config)

  def config
    @config ||= Wurk::Configuration.new.tap do |cfg|
      cfg.api_token(ADMIN_TOKEN, scopes: %i[admin])
      cfg.api_token(READ_TOKEN, scopes: %i[read])
      cfg.api_token(ENQUEUE_TOKEN, scopes: %i[enqueue])
    end
  end

  # Writes one heartbeat exactly as Wurk::Heartbeat#write_beat does — same SET
  # membership, same HASH fields, same `info` JSON — so the routes read
  # production bytes rather than a shape invented for the test.
  def beat(label, hostname: "box-#{@ns}", pid: 4321, tag: 'web', concurrency: 10, busy: 0,
           queues: %w[critical default], version: '1.2.3', embedded: false, quiet: false,
           rss: 100_000, rtt_us: 400, beat_at: nil, started_at: nil)
    identity = "#{hostname}:#{pid}:#{label}#{@ns}"
    info = {
      'hostname' => hostname, 'started_at' => started_at || (@now - 600), 'pid' => pid, 'tag' => tag,
      'concurrency' => concurrency, 'capsules' => { 'default' => { 'weights' => weights_for(queues) } },
      'labels' => ['x'], 'identity' => identity, 'version' => version, 'embedded' => embedded,
      'cpu_model' => 'Fake CPU', 'cores' => 8, 'memory_total_kb' => 16_000_000
    }
    @pool.with do |c|
      c.call('SADD', 'processes', identity)
      c.call('HSET', identity, 'info', Wurk.dump_json(info), 'concurrency', concurrency.to_s,
             'busy', busy.to_s, 'beat', (beat_at || @now).to_s, 'quiet', quiet.to_s,
             'rss', rss.to_s, 'rtt_us', rtt_us.to_s)
    end
    identity
  end

  # Descending weights, so the fixture exercises the capsule-derived `queues`
  # and `weights` accessors rather than the pre-capsule fallback fields.
  def weights_for(queues)
    queues.each_with_index.to_h { |queue, index| [queue, queues.size - index] }
  end

  def work(identity, jid:, queue: 'default', run_at: nil, thread_id: 'T0', payload_overrides: {})
    payload = {
      'class' => "SwarmWorker#{@ns}", 'args' => ['secret-value'], 'jid' => jid,
      'queue' => queue, 'created_at' => @now - 10
    }.merge(payload_overrides)
    entry = { 'queue' => queue, 'run_at' => run_at || @now, 'payload' => Wurk.dump_json(payload) }
    @pool.with { |c| c.call('HSET', "#{identity}:work", thread_id, Wurk.dump_json(entry)) }
  end

  def register_cron(schedule, queue: 'default', args: [])
    Wurk::Cron::Loop.new(schedule: schedule, klass: "CronWorker#{@ns}",
                         options: { 'queue' => queue, 'args' => args }).tap do |loop_obj|
      Wurk::Cron.persist(loop_obj)
    end
  end

  def signals(identity) = @pool.with { |c| c.call('LRANGE', "#{identity}-signals", 0, -1) }

  def row_for(rows, label) = rows.find { |row| row['identity'].include?(":#{label}#{@ns}") }

  # Wurk.redis_pool honours a per-thread capsule override, so a pool aimed at a
  # closed port reaches only this test's own calls.
  def with_unreachable_redis
    capsule = Struct.new(:redis_pool).new(
      Wurk::RedisPool.new(size: 1, url: 'redis://127.0.0.1:6399/0', name: 'unreachable')
    )
    Thread.current[:wurk_capsule] = capsule
    yield
  ensure
    Thread.current[:wurk_capsule] = nil
  end

  def call(env) = app.call(env)

  def get(path, token: ADMIN_TOKEN) = request('GET', path, token: token)
  def post(path, token: ADMIN_TOKEN) = request('POST', path, token: token)

  def request(method, path, token:)
    info, _, query = path.partition('?')
    parse(call(env_for(method, info, query: query, token: token)))
  end

  def parse(response)
    status, headers, body = response
    [status, headers, JSON.parse(body.join)]
  end

  def env_for(method, path, query: '', token: ADMIN_TOKEN)
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => '',
      'QUERY_STRING' => query,
      'rack.input' => StringIO.new,
      'rack.errors' => StringIO.new,
      'HTTP_AUTHORIZATION' => "Bearer #{token}"
    }
  end
end
