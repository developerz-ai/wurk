# frozen_string_literal: true

require_relative '../test_helper'

# F5 sweep. `RedisPool#with` now defaults to "the command may already have
# applied — do not replay the block", so a path that used to ride out a
# connection blip raises unless it claims apply-safety with `idempotent: true`.
#
# That claim is invisible to any test that only asserts returned data, and it is
# wrong in both directions: dropped from a read path in a refactor, a fetch loop
# stops surviving a failover it used to absorb; added to a path that moves,
# pushes or increments, a blip silently duplicates work. So every swept call site
# is pinned here — including the neighbours that must stay unclaimed.
class RedisIdempotentCallSitesTest < Wurk::Test::UnitCase
  parallelize_me!

  DEAD_PID = 999_999 # never a running pid in CI/dev

  # One checkout: the apply-safety claim it carried, plus the Redis command verbs
  # its block actually issued.
  Checkout = Struct.new(:idempotent, :commands)

  # Pairs each checkout's claim with the commands issued inside it, so a test can
  # say "the SCAN claimed, the LMOVE didn't" instead of asserting a positional
  # sequence that any unrelated new round trip would break.
  #
  # Subclasses the real pool because PoolCheckout dispatches on the RedisPool
  # type — a bare double would take the foreign-pool branch and prove nothing —
  # and delegates to a real connection, so the paths under test run their normal
  # logic against real Redis.
  class ClaimRecordingPool < Wurk::RedisPool
    def initialize(size: 2)
      super(size: size, name: 'claim-recording', url: Wurk::Test.redis_url)
      @checkouts = []
    end

    def with(idempotent: false, &block)
      log = []
      @checkouts << Checkout.new(idempotent, log)
      super { |conn| block.call(RecordingConn.new(conn, log)) }
    end

    # The claim of every checkout that issued `command`, in call order. Empty
    # when the command was never issued — assert on it and a call site that
    # silently stopped running shows up as a failure too.
    def claims_for(command)
      @checkouts.select { |c| c.commands.include?(command) }.map(&:idempotent)
    end

    def commands
      @checkouts.flat_map(&:commands)
    end
  end

  # Connection decorator that logs each command verb into its checkout's log.
  # Only the three entry points Wurk's own code uses are intercepted; anything
  # else a block reaches for is forwarded untouched.
  class RecordingConn
    def initialize(conn, log)
      @conn = conn
      @log = log
    end

    def call(*args, **, &)
      @log << args.first.to_s
      @conn.call(*args, **, &)
    end

    def blocking_call(timeout, *args, **, &)
      @log << args.first.to_s
      @conn.blocking_call(timeout, *args, **, &)
    end

    def pipelined
      @conn.pipelined { |pipe| yield RecordingConn.new(pipe, @log) }
    end

    def respond_to_missing?(name, include_private = false)
      @conn.respond_to?(name, include_private) || super
    end

    def method_missing(name, ...)
      @conn.public_send(name, ...)
    end
  end

  def setup
    super
    @ns = "ics-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @public_queue = Wurk::Keys.queue(@queue_name)
    @main = ClaimRecordingPool.new
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    on_recording_pools(@config)
  end

  def teardown
    @main.with do |conn|
      keys = conn.call('KEYS', "#{@public_queue}*")
      conn.call('DEL', *keys) unless keys.empty?
    end
    @main.disconnect!
    @fetch&.disconnect!
  ensure
    super
  end

  # --- fetcher ------------------------------------------------------------

  # An empty-poll SMEMBERS and the LMOVE that follows it are the two hottest
  # round trips in the process; both keep the connection backoff.
  def test_fetch_read_and_move_paths_claim_apply_safety
    enqueue('{"jid":"a"}')

    refute_nil fetcher.retrieve_work

    assert_equal [true], @main.claims_for('SMEMBERS')
    assert_equal [true], @main.claims_for('LMOVE')
  end

  # BLMOVE draws from the dedicated fetch pool, a separate checkout path, so its
  # claim is asserted on that pool — not the main one.
  def test_blmove_claims_apply_safety_on_the_fetch_pool
    @config.fetch_poll_interval = 0.05

    assert_nil fetcher.send(:blmove, @public_queue)

    assert_equal [true], @fetch.claims_for('BLMOVE')
    assert_empty @main.commands
  end

  # The ACK and the shutdown re-push are the other side of the same fetcher: an
  # RPUSH replayed after a lost reply is a duplicate job, so neither may claim.
  def test_ack_and_requeue_do_not_claim_apply_safety
    enqueue('{"jid":"b"}')
    uow = fetcher.retrieve_work
    uow.requeue
    uow.acknowledge

    assert_equal [false], @main.claims_for('RPUSH')
    assert_equal [false], @main.claims_for('LREM')
  end

  # --- reaper -------------------------------------------------------------

  # The sweep is all reads until it finds an orphan: SMEMBERS + HGET for
  # liveness, SCAN for the private lists.
  def test_reaper_read_paths_claim_apply_safety
    seed_processes_member
    seed_private_list([%({"jid":"#{@ns}-c"})])
    reaper.reclaim!

    assert_equal [true], @main.claims_for('SMEMBERS')
    assert_equal [true], @main.claims_for('HGET')
    assert_equal [true], @main.claims_for('SCAN').uniq
  end

  # Drain moves a job then poison-checks it. A replay would move the next job
  # and leave the moved one unchecked, so it stays unclaimed on purpose.
  def test_reaper_drain_does_not_claim_apply_safety
    seed_private_list([%({"jid":"#{@ns}-d"}), %({"jid":"#{@ns}-e"})])

    assert_equal 2, reaper.reclaim!

    assert_equal [false], @main.claims_for('LMOVE').uniq
  end

  private

  # Points every pool a subsystem can reach at a recorder: the default capsule's
  # main + fetch pools (Capsule#redis / #fetch_redis) and, through
  # Configuration#redis_pool, Component#redis and Wurk.redis.
  def on_recording_pools(config)
    @fetch = ClaimRecordingPool.new
    main = @main
    fetch = @fetch
    capsule = config.default_capsule
    capsule.define_singleton_method(:redis_pool) { main }
    capsule.define_singleton_method(:fetch_redis_pool) { fetch }
  end

  def fetcher
    @fetcher ||= begin
      @config.default_capsule.queues = [@queue_name]
      Wurk::Fetcher::Reliable.new(@config.default_capsule)
    end
  end

  def reaper
    @config.default_capsule.queues = [@queue_name]
    Wurk::Fetcher::Reaper.new(@config, interval: 1, lock_key: "#{@ns}-lock", full_lock_key: "#{@ns}-full")
  end

  def enqueue(payload)
    @main.with { |conn| conn.call('LPUSH', @public_queue, payload) }
  end

  # A private list owned by a dead pid in this process's own namespace, which the
  # reaper reads as an orphan via kill(0) without waiting out a heartbeat TTL.
  def seed_private_list(payloads)
    host = ENV['DYNO'] || Socket.gethostname
    key = "#{@public_queue}|#{host}|#{DEAD_PID}|#{Wurk::Component::PROCESS_NONCE}|0"
    @main.with { |conn| conn.call('LPUSH', key, *payloads) }
    key
  end

  # `live_owners` only pipelines the HGET liveness probe when `processes` has at
  # least one member, so the HGET claim needs a member to exist.
  def seed_processes_member
    identity = "#{@ns}:1:nonce"
    @main.with do |conn|
      conn.call('SADD', Wurk::Keys::PROCESSES, identity)
      conn.call('HSET', identity, 'info', '{}')
    end
  end
end
