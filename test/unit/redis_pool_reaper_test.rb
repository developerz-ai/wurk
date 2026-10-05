# frozen_string_literal: true

require_relative '../test_helper'

# `:redis_idle_timeout` (#537): checked-in connections idle past the timeout
# are closed and dropped; checked-out ones never are. Real Redis throughout —
# "closed" is asserted on the server's own CLIENT LIST, not on a stub.
class RedisPoolReaperTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @observer = RedisClient.new(url: Wurk::Test.redis_url)
  end

  def teardown
    @pool&.disconnect!
    @observer&.close
  ensure
    super
  end

  def test_connection_idle_past_the_timeout_is_closed_and_replaced
    @pool = build_pool(size: 2, redis_idle_timeout: 0.2)
    first = client_id

    assert_equal 1, @pool.idle
    wait_until('the idle connection is reaped') { @pool.idle.zero? }

    refute server_has_client?(first), 'the reaped connection must be closed server-side'
    assert_equal 2, @pool.available, 'a reaped slot stays free for the next checkout'
    refute_equal first, client_id, 'the next checkout dials a fresh connection'
  end

  def test_connection_idle_under_the_timeout_is_kept
    # Sweeps every 1.5s; the 2s wait spans one sweep that sees a 1.5s-old
    # connection, well inside the 3s timeout.
    @pool = build_pool(size: 1, redis_idle_timeout: 3)
    first = client_id
    sleep 2

    assert_equal 1, @pool.idle
    assert server_has_client?(first)
    assert_equal first, client_id
  end

  def test_checked_out_connection_outliving_the_window_is_kept
    @pool = build_pool(size: 2, redis_idle_timeout: 0.2)
    held_id = nil
    @pool.with do |conn|
      held_id = conn.call('CLIENT', 'ID')
      sleep 1

      assert_equal held_id, conn.call('CLIENT', 'ID'), 'an in-flight block keeps its connection'
    end

    assert server_has_client?(held_id)
    assert_equal held_id, client_id, 'checkin restarts the idle clock'
  end

  def test_nil_timeout_starts_no_reaper_and_reaps_nothing
    @pool = build_pool(size: 1, redis_idle_timeout: nil)
    first = client_id
    sleep 0.3

    assert_nil reaper_thread
    assert_equal 1, @pool.idle
    assert_equal first, client_id
  end

  def test_reaper_starts_on_first_checkout_and_stops_on_disconnect
    @pool = build_pool(size: 1, redis_idle_timeout: 5)

    assert_nil reaper_thread, 'no thread until the pool is used'
    client_id
    thread = reaper_thread

    assert_predicate thread, :alive?
    @pool.disconnect!

    refute_predicate thread, :alive?
    @pool = nil
  end

  def test_disconnected_pool_never_restarts_its_reaper
    @pool = build_pool(size: 1, redis_idle_timeout: 5)
    client_id
    @pool.disconnect!

    assert_raises(ConnectionPool::PoolShuttingDownError) { client_id }
    assert_nil reaper_thread
    @pool = nil
  end

  def test_child_runs_its_own_reaper_on_an_inherited_pool
    @pool = build_pool(size: 1, redis_idle_timeout: 0.2)
    parent_id = client_id
    parent_reaper = reaper_thread

    pid = ::Process.fork do
      child_id = client_id
      deadline = monotonic + 5
      sleep 0.05 until @pool.idle.zero? || monotonic > deadline
      reaper = reaper_thread
      ok = @pool.idle.zero? && reaper&.alive? && !reaper.equal?(parent_reaper) && child_id != parent_id
      exit!(ok ? 0 : 1)
    end
    _, status = ::Process.wait2(pid)

    assert_predicate status, :success?, 'the child must reap its own connections with its own reaper'
    assert_predicate parent_reaper, :alive?, 'the parent reaper is untouched by the fork'
  end

  def test_rejects_a_timeout_that_is_not_a_positive_number
    [0, -1, '60'].each do |bad|
      err = assert_raises(ArgumentError) { build_pool(redis_idle_timeout: bad) }

      assert_match(/redis_idle_timeout/, err.message)
    end
  end

  def test_configuration_hands_the_timeout_to_every_pool_it_builds
    config = Wurk::Configuration.new
    config.redis = { url: Wurk::Test.redis_url }

    assert_nil config.new_redis_pool(1, 'unset').redis_idle_timeout

    config.reap_idle_redis_connections

    assert_equal 60, config[:redis_idle_timeout]
    config.reap_idle_redis_connections(15)

    assert_equal 15, config.new_redis_pool(1, 'set').redis_idle_timeout
    assert_equal 15, config.web_redis_pool.redis_idle_timeout
  ensure
    config&.reset_redis_pools!
  end

  private

  def build_pool(size: 1, redis_idle_timeout: nil)
    @pool_name = "reaper-#{SecureRandom.hex(4)}"
    Wurk::RedisPool.new(size: size, url: Wurk::Test.redis_url, name: @pool_name,
                        redis_idle_timeout: redis_idle_timeout)
  end

  def client_id
    @pool.with { |conn| conn.call('CLIENT', 'ID') }
  end

  def server_has_client?(client_id)
    !@observer.call('CLIENT', 'LIST', 'ID', client_id.to_s).to_s.strip.empty?
  end

  def reaper_thread
    Thread.list.find { |t| t.name == "wurk-redis-reaper-#{@pool_name}" }
  end

  def wait_until(what, timeout: 5)
    deadline = monotonic + timeout
    sleep 0.02 until yield || monotonic > deadline

    assert yield, "timed out waiting until #{what}"
  end

  def monotonic
    ::Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
