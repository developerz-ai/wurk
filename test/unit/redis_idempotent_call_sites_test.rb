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

  # The capsule duck type `Wurk.redis_pool` resolves through, so a class that
  # reaches for the process-wide pool lands on the recorder instead.
  Handle = Struct.new(:redis_pool)

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
      keys = conn.call('KEYS', "*#{@ns}*")
      conn.call('DEL', *keys) unless keys.empty?
      conn.call('SREM', Wurk::Keys::PROCESSES, "#{@ns}:1:x")
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

  # The shutdown re-push is the other side of the same fetcher: an RPUSH
  # replayed after a lost reply is a duplicate job, so it must not claim.
  def test_requeue_does_not_claim_apply_safety
    enqueue('{"jid":"b"}')
    fetcher.retrieve_work.requeue

    assert_equal [false], @main.claims_for('RPUSH')
  end

  # The ACK claims, and had to: it no longer owns a checkout — it rides the
  # next fetch's pipeline, whose LMOVE claims. The claim is sound on its own
  # terms anyway. A replayed LREM finds the payload already gone and removes
  # nothing, because every job JSON carries a unique jid, and the poison-pill
  # DEL beside it is idempotent by definition. The standalone flush claims for
  # the same reason: it is the same two commands, on the drain path, where
  # riding out a blip is worth more than anywhere else.
  def test_the_ack_claims_apply_safety_on_both_the_piggybacked_and_flushed_paths
    enqueue('{"jid":"b"}')
    enqueue('{"jid":"c"}')
    fetcher.retrieve_work.acknowledge
    fetcher.retrieve_work.acknowledge
    fetcher.flush_pending_acks

    assert_equal [true, true], @main.claims_for('LREM')
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

  # --- data API (Stats / Queue / ProcessSet) ------------------------------

  # Everything the dashboard and third-party gems poll: counters, queue sizes,
  # latency, the process list. All pure reads, so all replayable.
  def test_data_api_read_paths_claim_apply_safety
    on_default_pool do
      Wurk::Stats.new.queues
      Wurk::Queue.new(@queue_name).size
      Wurk::ProcessSet.new(false).size
    end

    assert_equal [true], @main.claims_for('GET').uniq
    assert_equal [true], @main.claims_for('LLEN').uniq
    assert_equal [true], @main.claims_for('SCARD').uniq
  end

  # Pause/unpause converge on the membership the caller asked for, so a replay
  # after a lost reply lands on the same state — the claim documented on both.
  def test_queue_pause_and_unpause_claim_apply_safety
    queue = Wurk::Queue.new(@queue_name)
    on_default_pool do
      queue.pause!
      queue.unpause!
    end

    assert_equal [true], @main.claims_for('SADD')
    assert_equal [true], @main.claims_for('SREM')
  end

  # The writes among those reads: clearing a queue and zeroing the global
  # counters both wipe a container other writers append to.
  def test_data_api_writes_do_not_claim_apply_safety
    on_default_pool do
      Wurk::Queue.new(@queue_name).clear
      Wurk::Stats.new.reset
    end

    assert_equal [false], @main.claims_for('UNLINK')
    assert_equal [false], @main.claims_for('SET')
  end

  # --- web ----------------------------------------------------------------

  # A dashboard keystroke pages a queue LIST. Both round trips are reads, and
  # the scan budget is counted in Ruby, so a replayed page double-counts nothing.
  def test_web_search_queue_scan_claims_apply_safety
    on_default_pool do
      register_queue(%({"jid":"#{@ns}","class":"SearchHit"}))
      Wurk::Web::Search.new('SearchHit', kinds: %w[queues]).to_a
    end

    assert_equal [true], @main.claims_for('LLEN')
    assert_equal [true], @main.claims_for('LRANGE')
  end

  def test_web_search_sorted_set_scan_claims_apply_safety
    on_default_pool { Wurk::Web::Search.new('SearchHit', kinds: %w[retry]).to_a }

    assert_equal [true], @main.claims_for('ZSCAN')
  end

  # Listing limiters reads the SET, probes each name's metadata, and sweeps the
  # names whose metadata is gone. The sweep is the one write here, and it claims
  # too: its script re-decides liveness inside the atomic step, so a replay can
  # only drop names that are still dead.
  def test_web_limits_read_paths_claim_apply_safety
    @main.with do |c|
      c.call('SADD', Wurk::Limiter::LIST_KEY, "#{@ns}-lmtr")
      c.call('HSET', "lmtr:#{@ns}-lmtr", 'type', 'concurrent', 'options', '{}', 'fingerprint', 'fp')
      c.call('SADD', Wurk::Limiter::LIST_KEY, "#{@ns}-ghost")
    end

    on_default_pool { Wurk::Web::Enterprise::Limits.list }

    assert_equal [true], @main.claims_for('SMEMBERS')
    assert_equal [true], @main.claims_for('EXISTS')
    assert_equal [true], @main.claims_for('EVALSHA')
  end

  def test_web_limits_metadata_claims_apply_safety
    on_default_pool { Wurk::Web::Enterprise::Limits.metadata("#{@ns}-lmtr") }

    assert_equal [true], @main.claims_for('HGETALL')
  end

  # --- the five the audit named ------------------------------------------

  # Enqueue. Every command the push issues appends, so a replay is a second
  # copy of the job — the outage buffer, not the pool, is what retries here.
  def test_client_push_does_not_claim_apply_safety
    Wurk::Client.new(config: @config).push('class' => 'HardJob', 'args' => [], 'queue' => @queue_name)

    assert_equal [false], @main.claims_for('LPUSH')
  end

  # Scheduler promotion, both halves: the destructive ZPOPBYSCORE and the LPUSH
  # that re-queues what it popped.
  def test_scheduler_pop_and_promote_do_not_claim_apply_safety
    sset = "#{@ns}-schedule"
    @main.with { |c| c.call('ZADD', sset, '0', %({"class":"HardJob","args":[],"queue":"#{@queue_name}"})) }

    Wurk::Scheduled::Enq.new(@config).enqueue_jobs([sset])

    assert_equal [false], @main.claims_for('EVALSHA').uniq
    assert_equal [false], @main.claims_for('LPUSH').uniq
    assert_equal 1, @main.with { |c| c.call('LLEN', @public_queue) }.to_i
  end

  # Stats flush. INCRBY is additive, so a replayed pipeline counts the window
  # twice on every `stat:` key it touches. Driven straight at #write_stats: the
  # public #flush_stats would drain the process-wide Processor counters other
  # tests in this worker are also reading.
  def test_stats_flush_does_not_claim_apply_safety
    Wurk::Launcher.new(@config).send(:write_stats, 3, 1, 0)

    assert_equal [false], @main.claims_for('INCRBY')
  end

  # The beat is the one split call site: its writes converge on the same
  # identity hash and keep the backoff, while the signal LPOPs — a dashboard
  # TERM/TSTP each — get their own checkout that must never replay.
  def test_heartbeat_write_claims_apply_safety_but_the_signal_drain_does_not
    Wurk::Heartbeat.new(identity: "#{@ns}:1:x", config: @config).beat!

    assert_equal [true], @main.claims_for('HSET')
    assert_equal [false], @main.claims_for('LPOP')
  end

  # Poison-pill recovery counter: an over-count kills a healthy job.
  def test_poison_pill_counter_does_not_claim_apply_safety
    on_default_pool { Wurk::Middleware::PoisonPill.track!({ 'jid' => @ns, 'class' => 'HardJob' }, queue: @queue_name) }

    assert_equal [false], @main.claims_for('INCR')
  end

  private

  def on_default_pool
    prev = Thread.current[:wurk_capsule]
    Thread.current[:wurk_capsule] = Handle.new(@main)
    yield
  ensure
    Thread.current[:wurk_capsule] = prev
  end

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

  # Search walks `Queue.all`, so the queue has to be a `queues` SET member too,
  # not just a non-empty LIST.
  def register_queue(payload)
    @main.with do |conn|
      conn.call('SADD', Wurk::Keys::QUEUES_SET, @queue_name)
      conn.call('LPUSH', @public_queue, payload)
    end
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
