# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'rack/test'
require 'json'

# Slice 07, task 50 — `GET /v1/swarm` and `GET /v1/processes` against a real
# forked swarm (CLAUDE.md: never mock Redis in integration tests).
#
# test/unit/api_swarm_test.rb pins the roll-up math and the field shapes
# against hand-written heartbeat fixtures — the same technique
# test/unit/swarm_test.rb and friends use for the swarm internals. What only a
# real fork can prove is the thing the plan doc (07-http-producer-api.md
# "Tests") calls out by name: watching the swarm through the API costs the
# swarm nothing (Swarm.draw's module comment — `ProcessSet.new(false)`, no
# extra beat), and the process rows the API reports for real children are the
# same bytes `Wurk::Heartbeat#write_beat` put in Redis, not a shape the test
# invented. A synthetic ghost heartbeat sits beside them so the same request
# proves both a live row (`stale: false`) and a stale one (`stale: true`) came
# out of the identical code path.
class ApiV1SwarmTest < Wurk::Test::UnitCase
  parallelize_me!

  include ::Rack::Test::Methods

  ADMIN_TOKEN = 'api-v1-swarm-admin-token-0123456789'

  POLL_TIMEOUT = 15.0
  POLL_INTERVAL = 0.1

  # Comfortably past Serializers::STALE_AFTER_SECONDS (3 x BEAT_PAUSE = 30s)
  # so the ghost is unambiguously stale regardless of scheduling jitter.
  GHOST_BEAT_AGE = 90

  def setup
    super
    @ns = "apiswarm-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @now = Time.now.to_f
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:timeout] = 5
    @config.api_token(ADMIN_TOKEN, scopes: %i[admin])
    @observer_pool = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @ghost_identity = "ghost-box-#{@ns}:9999:a"
  end

  def teardown
    begin
      @swarm&.shutdown(timeout: 5)
    rescue StandardError
      nil
    end
    stop_supervisor_thread(@supervisor, 10)
    @observer_pool&.call('SREM', 'processes', @ghost_identity)
    @observer_pool&.call('DEL', @ghost_identity, "queue:#{@queue_name}")
    @observer_pool&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_processes_lists_real_forked_children_and_reports_a_stale_ghost
    pids = boot_swarm(2)
    write_ghost_heartbeat

    body = get_json('/v1/processes', count: 200)
    rows = body.fetch('processes')
    identities_by_pid = rows.to_h { |row| [row['identity'], row] }

    pids.each do |pid|
      row = identities_by_pid.values.find { |r| r['identity'].to_s.include?(":#{pid}:") }

      assert row, "expected a live process row for forked child pid #{pid} in #{rows.map { |r| r['identity'] }}"
      refute row['stale'], "a real child that just beat must not be reported stale: #{row}"
      assert_operator row['beat_age_seconds'], :<, 15.0, 'a child that just booted should have a fresh beat'
      assert_equal @queue_name, row['queues'].first
    end

    ghost = identities_by_pid[@ghost_identity]
    seen = rows.map { |r| r['identity'] }

    assert ghost, "expected the synthetic ghost heartbeat #{@ghost_identity} to appear in #{seen}"
    assert ghost['stale'], "a heartbeat #{GHOST_BEAT_AGE}s old must be reported stale: #{ghost}"
    assert_in_delta GHOST_BEAT_AGE, ghost['beat_age_seconds'], 5.0
  end

  def test_swarm_rolls_up_real_children_and_the_stale_ghost_into_one_answer
    pids = boot_swarm(2)
    write_ghost_heartbeat

    body = get_json('/v1/swarm')

    assert_equal pids.size + 1, body.dig('processes', 'total'),
                 'the roll-up must count every live process plus the stale ghost'
    assert_equal 1, body.dig('processes', 'stale')
    assert_includes body['queues'], @queue_name
    assert_operator body['concurrency'], :>=, pids.size
    assert_equal 30, body.dig('beat', 'stale_after_seconds')
    assert_operator body.dig('beat', 'oldest_age_seconds'), :>=, GHOST_BEAT_AGE - 5.0
  end

  private

  def boot_swarm(count)
    topology = Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
    @swarm = Wurk::Swarm.new(topology: topology, config: @config, shutdown_timeout: 5)
    pids = @swarm.boot(install_signals: false)
    @supervisor = Thread.new { @swarm.supervise }

    assert wait_for_pids?(pids), "expected heartbeats for #{pids} within #{POLL_TIMEOUT}s"
    pids
  end

  # Same bytes Wurk::Heartbeat#write_beat leaves — see test/unit/api_swarm_test.rb's
  # `beat` helper, which this mirrors — with a `beat` timestamp old enough that
  # Serializers.stale? reports it stale without waiting out a real heartbeat lapse.
  def write_ghost_heartbeat
    info = {
      'hostname' => "ghost-box-#{@ns}", 'started_at' => @now - 3600, 'pid' => 9999, 'tag' => 'ghost',
      'concurrency' => 1, 'capsules' => { 'default' => { 'weights' => { @queue_name => 1 } } },
      'labels' => [], 'identity' => @ghost_identity, 'version' => Wurk::VERSION, 'embedded' => false,
      'cpu_model' => 'Fake CPU', 'cores' => 1, 'memory_total_kb' => 1_000_000
    }
    @observer_pool.call('SADD', 'processes', @ghost_identity)
    @observer_pool.call('HSET', @ghost_identity, 'info', Wurk.dump_json(info), 'concurrency', '1',
                        'busy', '0', 'beat', (@now - GHOST_BEAT_AGE).to_s, 'quiet', 'false',
                        'rss', '10000', 'rtt_us', '400')
  end

  # Each forked child's identity is `<hostname>:<pid>:<nonce>` (swarm.rb) —
  # the hostname is the real machine's, not namespaced, so a pid substring
  # match is the only way to tell "this test's children" from a peer test
  # worker's live heartbeats on the same shared `processes` SET.
  def wait_for_pids?(pids)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      members = @observer_pool.call('SMEMBERS', 'processes')
      return true if pids.all? { |pid| members.any? { |identity| identity.include?(":#{pid}:") } }

      sleep POLL_INTERVAL
    end
    false
  end

  def monotonic_now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

  def stop_supervisor_thread(thread, timeout)
    return unless thread

    thread.join(timeout)
    thread.kill if thread.alive?
  end

  def app = @app ||= Wurk::API::App.new(config: @config)

  def get_json(path, **query)
    query_string = query.empty? ? '' : "?#{Rack::Utils.build_query(query)}"
    header 'Authorization', "Bearer #{ADMIN_TOKEN}"
    get("#{path}#{query_string}")

    assert_equal 200, last_response.status, last_response.body
    JSON.parse(last_response.body)
  end
end
