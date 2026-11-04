# frozen_string_literal: true

require_relative '../test_helper'

# Parity oracle for `Sidekiq::Config`, written from the documented promise in
# docs/target/sidekiq-free.md §4.1 (the DEFAULTS hash) and §4.2 (the public
# methods), not from Wurk's configuration code.
#
# Every assertion drives the public `Sidekiq::*` surface against a fresh
# `Sidekiq::Config` — never the process-global one, which other tests share —
# and observes the result of the call: a return value, an option's value, the
# capsule table, or a real Redis reply. The Redis paths talk to the suite's
# real server through the aliases; nothing here stubs a connection.
class ConfigParityTest < Wurk::Test::UnitCase
  parallelize_me!

  # A middleware class the chain cases register. Nothing about it is
  # Sidekiq-specific: a chain stores the class and its ctor args, nothing more.
  class PlainMiddleware
    def call(*)
      yield
    end
  end

  def setup
    super
    @config = Sidekiq::Config.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: Wurk::Test.redis_url }
  end

  def teardown
    @config&.reset_redis_pools!
    super
  end

  # --- §4.2 attr_reader :capsules -----------------------------------------

  def test_capsules_reader
    @config.capsule(:alpha)

    assert_kind_of Hash, @config.capsules
    assert_includes @config.capsules.keys, 'alpha'
    assert_equal 'alpha', @config.capsules['alpha'].name
  end

  # --- §4.2 attr_accessor :thread_priority ---------------------------------

  def test_thread_priority_default
    assert_equal(-1, @config.thread_priority)
    assert_equal(-1, Sidekiq::Component::DEFAULT_THREAD_PRIORITY)
  end

  def test_thread_priority_assignment
    @config.thread_priority = 2

    assert_equal 2, @config.thread_priority
  end

  # --- §4.2 def [], []=, fetch, key?, has_key?, merge!, dig -----------------

  def test_option_read
    config = Sidekiq::Config.new(timeout: 7)

    assert_equal 7, config[:timeout]
  end

  def test_option_write
    @config[:timeout] = 9

    assert_equal 9, @config[:timeout]
    assert_equal 9, @config.fetch(:timeout)
  end

  def test_option_fetch
    assert_equal 25, @config.fetch(:timeout)
    assert_equal :fallback, @config.fetch(:missing, :fallback)
    assert_raises(KeyError) { @config.fetch(:missing) }
  end

  def test_option_key
    @config[:present] = nil

    assert @config.key?(:present)
    refute @config.key?(:absent)
  end

  def test_option_has_key
    @config[:present] = nil

    # §4.2 lists `key?` and `has_key?` as two names for the same question, so
    # the oracle asks the alias by the name the document gives it.
    assert @config.has_key?(:present) # rubocop:disable Style/PreferredHashMethods
    refute @config.has_key?(:absent) # rubocop:disable Style/PreferredHashMethods
  end

  def test_option_merge
    @config.merge!(timeout: 3, dead_max_jobs: 42)

    assert_equal 3, @config[:timeout]
    assert_equal 42, @config[:dead_max_jobs]
    assert_equal :raise, @config[:on_complex_arguments]
  end

  def test_option_dig
    @config[:nested] = { a: { b: 7 } }

    assert_equal 7, @config.dig(:nested, :a, :b)
    assert_nil @config.dig(:nested, :a, :missing)
  end

  # --- §4.2 def inspect ----------------------------------------------------

  def test_inspect
    text = @config.inspect

    assert_kind_of String, text
    refute_empty text
    assert_includes text, @config.class.name
    assert_includes text, 'capsules='
  end

  # --- §4.2 default capsule shortcuts --------------------------------------

  def test_concurrency_default
    assert_equal 5, @config.concurrency
    assert_equal 5, @config.default_capsule.concurrency
  end

  def test_concurrency_capsule
    @config.concurrency = 9

    assert_equal 9, @config.default_capsule.concurrency
    assert_equal 9, @config.concurrency
  end

  def test_queues_default
    assert_equal ['default'], @config.queues
  end

  def test_queues_capsule
    @config.queues = ['critical']

    assert_equal ['critical'], @config.default_capsule.queues
    assert_equal ['critical'], @config.queues
  end

  def test_total_concurrency
    @config.capsule(:alpha).concurrency = 2
    @config.capsule(:beta).concurrency = 3

    assert_equal 5, @config.total_concurrency
  end

  # --- §4.2 capsules --------------------------------------------------------

  def test_default_capsule
    yielded = nil
    capsule = @config.default_capsule { |cap| yielded = cap }

    assert_same capsule, yielded
    assert_equal 'default', capsule.name
  end

  def test_named_capsule
    first = @config.capsule(:alpha)
    second = @config.capsule(:alpha)

    assert_same first, second
    assert_equal 'alpha', first.name
    assert_equal ['alpha'], @config.capsules.keys
  end

  # --- §4.2 middleware ------------------------------------------------------

  def test_client_middleware
    yielded = nil
    chain = @config.client_middleware do |c|
      yielded = c
      c.add(PlainMiddleware)
    end

    assert_same chain, yielded
    assert_kind_of Sidekiq::Middleware::Chain, chain
    assert chain.exists?(PlainMiddleware)
    assert_equal [PlainMiddleware], chain.entries.map(&:klass)
  end

  def test_server_middleware
    yielded = nil
    chain = @config.server_middleware do |c|
      yielded = c
      c.add(PlainMiddleware)
    end

    assert_same chain, yielded
    assert_kind_of Sidekiq::Middleware::Chain, chain
    assert chain.exists?(PlainMiddleware)
    assert_equal [PlainMiddleware], chain.entries.map(&:klass)
  end

  # --- §4.2 redis -----------------------------------------------------------

  def test_redis_merge
    @config.redis = { url: Wurk::Test.redis_url, size: 7 }
    @config.redis = { size: 9 }

    assert_equal Wurk::Test.redis_url, @config.redis_config[:url]
    assert_equal 9, @config.redis_config[:size]
  end

  def test_redis_reap
    @config.reap_idle_redis_connections

    assert_equal 60, @config[:redis_idle_timeout]

    @config.reap_idle_redis_connections(5)

    assert_equal 5, @config[:redis_idle_timeout]
  end

  def test_redis_pool
    assert_same @config.default_capsule.redis_pool, @config.redis_pool
  end

  def test_new_redis_pool
    pool = @config.new_redis_pool(3, 'parity-custom')

    begin
      pong = pool.with { |conn| conn.call('PING') }

      assert_equal 3, pool.size
      assert_equal 'PONG', pong
    ensure
      pool.disconnect!
    end
  end

  def test_redis_yield
    result = @config.redis { |conn| conn.call('PING') }

    assert_equal 'PONG', result
  end

  # §4.2 `def redis { |conn| ... }` — "yield connection with
  # READONLY/NOREPLICAS/UNBLOCKED retry".
  #
  # The retry under test is Wurk's, and it runs against the real server: the
  # block below is handed a real pooled connection and the successful attempt
  # pings the real Redis. Only the *trigger* is staged — a Redis server
  # produces "UNBLOCKED ..." only for a client it unblocked with CLIENT
  # UNBLOCK, and the suite's server is not required to implement that command
  # (Dragonfly does not). The error raised inside the block carries the exact
  # message Redis uses, so the pool classifies it the way it classifies the
  # server's own reply: close the connection, report the retry, run the block
  # again on a fresh socket.
  #
  # The block issues a real command before the error, so the connection is
  # open when the reply comes back: the pool has to close it and dial a new
  # one, and the server-side connection id (CLIENT ID) is what proves it did.
  # A pool that kept the failed connection would hand the retry the same
  # socket, and the two ids would match.
  #
  # `idempotent: true` is what makes that replay legal: the block already
  # completed a round trip, and the pool refuses to replay a block it cannot
  # prove applied nothing (Wurk::RedisPool#replayable?). Both commands here
  # are reads, so running the block again changes nothing.
  def test_redis_unblocked_retry
    attempts = 0
    reports = []
    connections = []
    @config.on_redis_error { |info| reports << info }

    value = @config.redis(idempotent: true) do |conn|
      attempts += 1
      connections << conn.call('CLIENT', 'ID')
      raise RedisClient::CommandError, 'UNBLOCKED The client has been unblocked via CLIENT UNBLOCK' if attempts == 1

      conn.call('PING')
    end

    assert_equal 'PONG', value
    assert_equal 2, attempts
    assert_equal 1, reports.size
    assert reports.first[:retried]
    assert_match(/\AUNBLOCKED/, reports.first[:error].message)
    refute_equal connections.first, connections.last,
                 'the retry ran on a new server-side connection: the failed one was closed'
  end

  # §4.2 `def redis { |conn| ... }` — "yield connection with
  # READONLY/NOREPLICAS/UNBLOCKED retry".
  #
  # A READONLY reply is what a replica answers when it is asked to write. The
  # retry under test is Wurk's, and it runs against the real server: the block
  # below is handed a real pooled connection and the successful attempt pings
  # the real Redis. Only the *trigger* is staged — the suite runs against one
  # single-node Redis, which never produces "READONLY" on its own, and
  # faking Redis is not allowed in a parity oracle. The error raised inside
  # the block carries the exact message Redis uses, so the pool classifies it
  # the way it classifies the server's own reply: close the connection,
  # report the retry, run the block again on a fresh socket.
  #
  # The command before the error puts a real round trip on the wire, so the
  # connection is open when the reply comes back and the retry has to dial a
  # new one: the server-side connection ids are what prove it. See the
  # UNBLOCKED case above for why the block claims idempotency.
  def test_redis_readonly_retry
    attempts = 0
    reports = []
    connections = []
    @config.on_redis_error { |info| reports << info }

    value = @config.redis(idempotent: true) do |conn|
      attempts += 1
      connections << conn.call('CLIENT', 'ID')
      raise RedisClient::CommandError, 'READONLY You can\'t write against a read only replica.' if attempts == 1

      conn.call('PING')
    end

    assert_equal 'PONG', value
    assert_equal 2, attempts
    assert_equal 1, reports.size
    assert reports.first[:retried]
    assert_match(/\AREADONLY/, reports.first[:error].message)
    refute_equal connections.first, connections.last,
                 'the retry ran on a new server-side connection: the failed one was closed'
  end

  # §4.2 `def redis { |conn| ... }` — "yield connection with
  # READONLY/NOREPLICAS/UNBLOCKED retry".
  #
  # NOREPLICAS is what a cluster member answers when it no longer has a
  # replica to serve from. Staged exactly like the READONLY case above: the
  # real pooled connection and the successful ping are real, and only the
  # server's own message is raised inside the block.
  def test_redis_noreplicas_retry
    attempts = 0
    reports = []
    connections = []
    @config.on_redis_error { |info| reports << info }

    value = @config.redis(idempotent: true) do |conn|
      attempts += 1
      connections << conn.call('CLIENT', 'ID')
      raise RedisClient::CommandError, 'NOREPLICAS Not enough good replicas to respond.' if attempts == 1

      conn.call('PING')
    end

    assert_equal 'PONG', value
    assert_equal 2, attempts
    assert_equal 1, reports.size
    assert reports.first[:retried]
    assert_match(/\ANOREPLICAS/, reports.first[:error].message)
    refute_equal connections.first, connections.last,
                 'the retry ran on a new server-side connection: the failed one was closed'
  end

  # The same retry on the default path: a failover reply raised before the
  # block issued anything is proof that nothing applied, so the pool replays
  # the block without the caller claiming it idempotent.
  def test_redis_failover_retry_replays_a_clean_block
    attempts = 0
    reports = []
    @config.on_redis_error { |info| reports << info }

    value = @config.redis do |conn|
      attempts += 1
      raise RedisClient::CommandError, 'READONLY You can\'t write against a read only replica.' if attempts == 1

      conn.call('PING')
    end

    assert_equal 'PONG', value
    assert_equal 2, attempts
    assert_equal 1, reports.size
    assert reports.first[:retried]
  end

  # --- §4.2 service locator -------------------------------------------------

  def test_registry_register
    service = Object.new
    @config.register(:parity_service, service)

    assert_same service, @config.lookup(:parity_service)
  end

  def test_registry_default
    default = Class.new

    service = @config.lookup(:parity_missing, default)

    assert_instance_of default, service
    assert_same service, @config.lookup(:parity_missing, default)
  end

  # --- §4.2 def freeze! -----------------------------------------------------

  def test_freeze
    @config.freeze!

    assert_predicate @config, :frozen?
    assert_raises(FrozenError) { @config[:timeout] = 1 }
    assert_raises(FrozenError) { @config.merge!(timeout: 1) }
  end

  # --- §4.2 handlers --------------------------------------------------------

  def test_death_handlers
    handler = ->(_job, _ex) { :handled }

    assert_kind_of Array, @config.death_handlers
    @config.death_handlers << handler

    assert_includes @config.death_handlers, handler
  end

  def test_poll_interval
    @config.average_scheduled_poll_interval = 12

    assert_equal 12, @config[:average_scheduled_poll_interval]
  end

  # --- §4.2 lifecycle hooks -------------------------------------------------

  def test_lifecycle_hooks
    events = %i[startup quiet shutdown exit heartbeat beat]
    blocks = events.to_h { |event| [event, proc { event }] }

    blocks.each { |event, block| @config.on(event, &block) }

    events.each do |event|
      assert_includes @config[:lifecycle_events][event], blocks[event]
    end
    assert_raises(ArgumentError) { @config.on(:not_an_event) { nil } }
  end

  # --- §4.2 def logger / logger= --------------------------------------------

  def test_logger_accessors
    logger = ::Logger.new(IO::NULL)
    @config.logger = logger

    assert_same logger, @config.logger
  end
end
