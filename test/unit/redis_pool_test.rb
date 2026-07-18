# frozen_string_literal: true

require_relative '../test_helper'

class RedisPoolTest < Wurk::Test::UnitCase
  parallelize_me!

  def teardown
    @pool&.disconnect!
  rescue ConnectionPool::PoolShuttingDownError
    # already shut down by the test body
  ensure
    super
  end

  # --- RedisConnection.create (#163, spec §26) ---

  def test_redis_connection_create_returns_usable_pool
    @pool = Wurk::RedisConnection.create(url: Wurk::Test.redis_url, size: 3)

    assert_instance_of Wurk::RedisPool, @pool
    assert_equal 3, @pool.size
    assert_equal('PONG', @pool.with { |c| c.call('PING') })
  end

  def test_redis_connection_create_accepts_string_keys
    @pool = Wurk::RedisConnection.create('url' => Wurk::Test.redis_url, 'size' => 2, 'pool_timeout' => 3)

    assert_equal 2, @pool.size
    assert_equal 3, @pool.pool_timeout
  end

  def test_redis_connection_create_defaults_size_when_omitted
    @pool = Wurk::RedisConnection.create(url: Wurk::Test.redis_url)

    assert_equal Wurk::RedisConnection::DEFAULT_POOL_SIZE, @pool.size
  end

  # --- happy path (real Redis) ---

  def test_initialize_stores_size
    @pool = Wurk::RedisPool.new(size: 4, url: Wurk::Test.redis_url, pool_timeout: 2, name: 'primary')

    assert_equal 4, @pool.size
  end

  def test_initialize_stores_url_timeout_and_name
    @pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, pool_timeout: 2, name: 'primary')

    assert_equal Wurk::Test.redis_url, @pool.url
    assert_equal 2, @pool.pool_timeout
    assert_equal 'primary', @pool.name
  end

  def test_initialize_uses_documented_defaults_when_omitted
    @pool = Wurk::RedisPool.new(size: 1)

    assert_equal Wurk::RedisPool::DEFAULT_URL, @pool.url
    assert_equal Wurk::RedisPool::DEFAULT_POOL_TIMEOUT, @pool.pool_timeout
    assert_equal Wurk::RedisPool::DEFAULT_NAME, @pool.name
  end

  # --- split checkout vs socket timeouts (#101) ---

  SOCKET_KEYS = %i[connect_timeout read_timeout write_timeout reconnect_attempts].freeze

  def test_socket_timeouts_default_to_documented_split
    @pool = build_pool
    expected = {
      connect_timeout: Wurk::RedisPool::DEFAULT_CONNECT_TIMEOUT,
      read_timeout: Wurk::RedisPool::DEFAULT_READ_TIMEOUT,
      write_timeout: Wurk::RedisPool::DEFAULT_WRITE_TIMEOUT,
      reconnect_attempts: Wurk::RedisPool::DEFAULT_RECONNECT_ATTEMPTS
    }

    assert_equal expected, @pool.client_config.slice(*SOCKET_KEYS)
  end

  def test_read_write_defaults_are_wider_than_connect_and_checkout
    assert_operator Wurk::RedisPool::DEFAULT_READ_TIMEOUT, :>, Wurk::RedisPool::DEFAULT_CONNECT_TIMEOUT
    assert_operator Wurk::RedisPool::DEFAULT_WRITE_TIMEOUT, :>, Wurk::RedisPool::DEFAULT_POOL_TIMEOUT
  end

  def test_split_timeouts_are_configured_independently
    @pool = Wurk::RedisPool.new(
      size: 1, url: Wurk::Test.redis_url, name: 'split',
      pool_timeout: 0.5, connect_timeout: 0.7, read_timeout: 5.0, write_timeout: 3.0, reconnect_attempts: 2
    )

    assert_in_delta 0.5, @pool.pool_timeout
    assert_equal({ connect_timeout: 0.7, read_timeout: 5.0, write_timeout: 3.0, reconnect_attempts: 2 },
                 @pool.client_config.slice(*SOCKET_KEYS))
  end

  def test_pool_timeout_is_not_forwarded_to_the_client_config
    @pool = build_pool(pool_timeout: 0.25)

    assert_in_delta 0.25, @pool.pool_timeout
    refute @pool.client_config.key?(:pool_timeout), 'pool_timeout is a checkout knob, not a socket one'
  end

  def test_forwards_unknown_keys_to_redis_client_verbatim
    @pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, name: 'drv', driver: :ruby)

    assert_equal :ruby, @pool.client_config[:driver]
    assert_equal('PONG', @pool.with { |c| c.call('PING') })
  end

  def test_with_yields_a_usable_redis_connection
    @pool = build_pool

    assert_equal('PONG', @pool.with { |c| c.call('PING') })
  end

  def test_with_returns_block_result
    @pool = build_pool

    assert_equal(:sentinel, @pool.with { :sentinel })
  end

  def test_pool_reuses_connections_in_single_slot
    @pool = build_pool(size: 1)
    ids = 3.times.map { @pool.with { |c| c.call('CLIENT', 'ID') } }

    assert_equal 1, ids.uniq.length, 'single-slot pool must reuse one socket'
  end

  def test_info_returns_parsed_hash
    @pool = build_pool
    info = @pool.info

    assert_kind_of Hash, info
    assert info.key?('redis_version'), 'expected redis_version in INFO output'
    refute(info.keys.any? { |k| k.start_with?('#') }, 'section headers must be stripped')
  end

  def test_disconnect_makes_pool_unusable
    @pool = build_pool
    @pool.with { |c| c.call('PING') }
    @pool.disconnect!
    assert_raises(ConnectionPool::PoolShuttingDownError) do
      @pool.with { |c| c.call('PING') }
    end
  end

  # --- retry semantics (isolated via fake conn) ---

  def test_retries_once_on_readonly
    conn = FlakyConn.new(kind: :readonly, raises: 1)
    pool = pool_wrapping(conn)

    assert_equal(:ok, pool.with(&:exec))
    assert_equal 2, conn.calls
    assert_equal 1, conn.closes
  end

  def test_retries_once_on_noreplicas
    conn = FlakyConn.new(kind: :noreplicas, raises: 1)
    pool = pool_wrapping(conn)

    assert_equal(:ok, pool.with(&:exec))
    assert_equal 2, conn.calls
  end

  def test_retries_once_on_unblocked
    conn = FlakyConn.new(kind: :unblocked, raises: 1)
    pool = pool_wrapping(conn)

    assert_equal(:ok, pool.with(&:exec))
    assert_equal 2, conn.calls
  end

  def test_does_not_retry_other_command_errors
    conn = FlakyConn.new(kind: :other, raises: 1)
    pool = pool_wrapping(conn)
    err = assert_raises(RedisClient::CommandError) { pool.with(&:exec) }

    assert_match(/wrong number of arguments/, err.message)
    assert_equal 0, conn.closes
  end

  # --- connection-error backoff (#101) ---

  def test_retries_connection_error_with_backoff_then_succeeds
    conn = FlakyConn.new(kind: :timeout, raises: 1)
    pool = pool_wrapping(conn)

    no_sleep(pool) { assert_equal(:ok, pool.with(&:exec)) }
    assert_equal 2, conn.calls
    assert_equal 1, conn.closes, 'connection is closed before the backoff retry'
  end

  def test_retries_cannot_connect_error
    conn = FlakyConn.new(kind: :cannot_connect, raises: 1)
    pool = pool_wrapping(conn)

    no_sleep(pool) { assert_equal(:ok, pool.with(&:exec)) }
    assert_equal 2, conn.calls
  end

  def test_connection_error_retries_to_the_cap_then_raises
    conn = FlakyConn.new(kind: :timeout, raises: 99)
    pool = pool_wrapping(conn)

    no_sleep(pool) { assert_raises(RedisClient::ConnectionError) { pool.with(&:exec) } }
    assert_equal Wurk::RedisPool::CONN_MAX_ATTEMPTS, conn.calls
    assert_equal Wurk::RedisPool::CONN_MAX_ATTEMPTS - 1, conn.closes
  end

  # --- telemetry hook ---

  def test_notifies_on_each_retry_and_the_final_give_up
    events = []
    conn = FlakyConn.new(kind: :timeout, raises: 99)
    pool = pool_wrapping(conn, on_error: ->(info) { events << info })

    no_sleep(pool) { assert_raises(RedisClient::ConnectionError) { pool.with(&:exec) } }

    summary = events.map { |e| [e[:attempt], e[:retried], e[:pool], e[:error].class] }

    assert_equal([[1, true, 'fake', RedisClient::ConnectionError],
                  [2, true, 'fake', RedisClient::ConnectionError],
                  [3, false, 'fake', RedisClient::ConnectionError]], summary)
  end

  def test_notifies_on_failover_retry
    events = []
    conn = FlakyConn.new(kind: :readonly, raises: 1)
    pool = pool_wrapping(conn, on_error: ->(info) { events << info })

    assert_equal(:ok, pool.with(&:exec))
    assert_equal([{ attempt: 1, retried: true }], events.map { |e| e.slice(:attempt, :retried) })
  end

  def test_does_not_notify_on_non_transient_errors
    events = []
    conn = FlakyConn.new(kind: :other, raises: 1)
    pool = pool_wrapping(conn, on_error: ->(info) { events << info })

    assert_raises(RedisClient::CommandError) { pool.with(&:exec) }
    assert_empty events
  end

  def test_a_raising_telemetry_hook_never_breaks_the_retry_path
    conn = FlakyConn.new(kind: :timeout, raises: 1)
    pool = pool_wrapping(conn, on_error: ->(_info) { raise 'telemetry boom' })

    no_sleep(pool) { assert_equal(:ok, pool.with(&:exec)) }
  end

  # --- pool checkout-timeout retry ---

  def test_retries_checkout_timeout_once_then_succeeds
    fake = FlakyCheckoutPool.new(FlakyConn.new(kind: :readonly, raises: 0), timeouts: 1)
    pool = pool_over(fake)

    no_checkout_sleep(pool) { assert_equal(:ok, pool.with(&:exec)) }
    assert_equal 2, fake.calls, 'one retry → two checkout attempts'
  end

  def test_checkout_timeout_retries_exactly_once_then_raises
    events = []
    fake = FlakyCheckoutPool.new(FlakyConn.new(kind: :readonly, raises: 0), timeouts: 99)
    pool = pool_over(fake, on_error: ->(info) { events << info })

    no_checkout_sleep(pool) { assert_raises(ConnectionPool::TimeoutError) { pool.with { :never } } }
    assert_equal 2, fake.calls, 'no loop: one retry only'
    assert_equal([true, false], events.map { |e| e[:retried] })
  end

  # --- backoff timing formulas ---

  def test_backoff_delay_grows_exponentially_within_jitter
    pool = build_pool

    assert_includes(1.0...1.25, pool.send(:backoff_delay, 1))
    assert_includes(2.0...2.25, pool.send(:backoff_delay, 2))
  end

  def test_checkout_delay_within_documented_window
    pool = build_pool

    assert_includes(0.1...0.3, pool.send(:checkout_delay))
  end

  # --- pool stats for heartbeat ---

  def test_available_reports_free_slots
    @pool = build_pool(size: 3)

    assert_equal 3, @pool.available
    @pool.with { assert_equal 2, @pool.available }
    assert_equal 3, @pool.available
  end

  def test_info_exposes_pool_stats
    @pool = build_pool(size: 2)
    info = @pool.info

    assert_equal 2, info['size']
    assert_equal 2, info['available']
    assert info.key?('redis_version'), 'still carries Redis INFO'
  end

  def test_reraises_after_a_single_retry
    conn = FlakyConn.new(kind: :readonly, raises: 2)
    pool = pool_wrapping(conn)
    err = assert_raises(RedisClient::ReadOnlyError) { pool.with(&:exec) }

    assert_match(/READONLY/, err.message)
    assert_equal 2, conn.calls
  end

  def test_only_closes_once_when_retry_also_fails
    conn = FlakyConn.new(kind: :readonly, raises: 2)
    pool = pool_wrapping(conn)
    assert_raises(RedisClient::ReadOnlyError) { pool.with(&:exec) }

    assert_equal 1, conn.closes
  end

  def test_swallows_close_errors_during_retry
    conn = FlakyConn.new(kind: :readonly, raises: 1, close_raises: true)
    pool = pool_wrapping(conn)

    assert_equal(:ok, pool.with(&:exec))
  end

  private

  def build_pool(size: 1, pool_timeout: 1, name: 'test')
    Wurk::RedisPool.new(size: size, url: Wurk::Test.redis_url, pool_timeout: pool_timeout, name: name)
  end

  def pool_wrapping(conn, on_error: nil)
    pool_over(FakePool.new(conn), on_error: on_error)
  end

  # Swap in a fake @pool so retry tests never open a real socket → deterministic
  # and fast. A real socket is still built (and immediately shadowed) so
  # client_config etc. stay populated.
  def pool_over(fake_pool, on_error: nil)
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, pool_timeout: 1, name: 'fake', on_error: on_error)
    pool.instance_variable_set(:@pool, fake_pool)
    pool
  end

  # Neutralize the retry sleeps so tests stay instant. Minitest 6 dropped
  # minitest/mock, so shadow the (private) delay methods on the throwaway pool
  # instance directly — no restore needed, the instance dies with the test.
  def no_sleep(pool)
    pool.define_singleton_method(:backoff_delay) { |_attempt| 0 }
    yield
  end

  def no_checkout_sleep(pool)
    pool.define_singleton_method(:checkout_delay) { 0 }
    yield
  end

  # Stand-in for a ConnectionPool that always yields the same fake conn.
  # Avoids opening a real socket so retry tests run deterministic and fast.
  class FakePool
    def initialize(conn)
      @conn = conn
    end

    def with
      yield @conn
    end

    def shutdown(&)
      # no-op
    end
  end

  # Raises ConnectionPool::TimeoutError on the first `timeouts` checkouts, then
  # yields the conn — exercises the out-of-block checkout-timeout retry.
  class FlakyCheckoutPool
    attr_reader :calls

    def initialize(conn, timeouts:)
      @conn = conn
      @timeouts = timeouts
      @calls = 0
    end

    def with
      @calls += 1
      raise ConnectionPool::TimeoutError, 'Waited 1 sec' if @calls <= @timeouts

      yield @conn
    end

    def shutdown(&); end
  end

  class FlakyConn
    ERRORS = {
      readonly: [RedisClient::ReadOnlyError, "READONLY You can't write against a read only replica."],
      noreplicas: [RedisClient::CommandError, 'NOREPLICAS Not enough good replicas to write.'],
      unblocked: [RedisClient::CommandError,
                  'UNBLOCKED force unblock from blocking operation, instance state changed (master -> replica?)'],
      other: [RedisClient::CommandError, 'ERR wrong number of arguments'],
      timeout: [RedisClient::ConnectionError, 'Connection timed out'],
      cannot_connect: [RedisClient::CannotConnectError, 'Errno::ECONNREFUSED']
    }.freeze

    attr_reader :calls, :closes

    def initialize(kind:, raises:, close_raises: false)
      @kind = kind
      @raises = raises
      @close_raises = close_raises
      @calls = 0
      @closes = 0
    end

    def exec
      @calls += 1
      if @calls <= @raises
        klass, msg = ERRORS.fetch(@kind)
        raise klass, msg
      end
      :ok
    end

    def close
      @closes += 1
      raise 'boom' if @close_raises
    end
  end
end
