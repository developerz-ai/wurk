# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::Queue pause/unpause + fetcher filter against real Redis.
# Membership of the `paused` SET is the single source of truth: Queue
# methods read/write it, and the reliable fetcher skips any queue whose
# unprefixed name is a member.
#
# Spec: docs/target/sidekiq-pro.md §6 (Queue pause/resume).
class QueuePauseTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns       = "#{Process.pid}-#{object_id}"
    @qname    = "qpause-#{@ns}"
    @other    = "qpause-other-#{@ns}"
    @rqname   = "queue:#{@qname}"
    @rotherq  = "queue:#{@other}"
    @pool     = Wurk.configuration.redis_pool
    clean_keys
  end

  def teardown
    clean_keys
  ensure
    super
  end

  # --- pause! / unpause! / paused? ----------------------------------

  def test_paused_predicate_false_when_set_empty
    refute_predicate Wurk::Queue.new(@qname), :paused?
  end

  def test_pause_adds_name_to_paused_set
    Wurk::Queue.new(@qname).pause!

    assert_includes paused_members, @qname
  end

  def test_pause_flips_paused_predicate
    q = Wurk::Queue.new(@qname)
    q.pause!

    assert_predicate q, :paused?
  end

  def test_pause_returns_true
    assert(Wurk::Queue.new(@qname).pause!)
  end

  def test_pause_is_idempotent
    q = Wurk::Queue.new(@qname)
    q.pause!
    q.pause!

    assert_equal 1, paused_members.count(@qname)
  end

  def test_unpause_removes_name_from_paused_set
    q = Wurk::Queue.new(@qname)
    q.pause!
    q.unpause!

    refute_includes paused_members, @qname
  end

  def test_unpause_flips_paused_predicate
    q = Wurk::Queue.new(@qname)
    q.pause!
    q.unpause!

    refute_predicate q, :paused?
  end

  def test_unpause_returns_true
    assert(Wurk::Queue.new(@qname).unpause!)
  end

  def test_unpause_is_idempotent_when_not_paused
    assert(Wurk::Queue.new(@qname).unpause!)
    refute_predicate Wurk::Queue.new(@qname), :paused?
  end

  def test_pause_only_affects_named_queue
    Wurk::Queue.new(@qname).pause!

    refute_predicate Wurk::Queue.new(@other), :paused?
  end

  # --- fetcher integration -------------------------------------------

  def test_fetcher_queues_cmd_excludes_paused_queue
    fetcher, capsule = build_fetcher(%W[#{@qname} #{@other}])
    Wurk::Queue.new(@qname).pause!

    refute_includes fetcher.queues_cmd, @rqname
    assert_includes fetcher.queues_cmd, @rotherq
  ensure
    capsule&.stop
  end

  def test_fetcher_queues_cmd_returns_empty_when_all_paused
    fetcher, capsule = build_fetcher(%W[#{@qname} #{@other}])
    Wurk::Queue.new(@qname).pause!
    Wurk::Queue.new(@other).pause!

    assert_empty fetcher.queues_cmd
  ensure
    capsule&.stop
  end

  # F1 regression: with every queue paused, retrieve_work has nothing to
  # BLMOVE on, so it must back off a full poll interval per pass rather than
  # returning nil instantly. A caller that drives retrieve_work in a bare loop
  # (Processor#run has no pause of its own) would otherwise spin as fast as the
  # CPU allows, burning a core on passes that can never return a job.
  def test_fetcher_backs_off_with_bounded_redis_commands_when_all_paused
    fetcher, capsule, counter = build_paused_fetcher_with_counter

    results = drain_for_one_second(fetcher)

    # Backed off at 0.05s/pass, ~1s of wall clock caps this well under 40
    # passes; a hot spin (no backoff) would blow past this by orders of
    # magnitude. Checkouts are bounded twice over — by the backoff and by
    # PAUSED_TTL — so they can only come in under the pass count.
    assert(results.all?(&:nil?))
    assert_operator results.size, :<=, 40
    assert_operator counter.count, :<=, 40
  ensure
    capsule&.stop
  end

  def test_fetcher_skips_paused_queue_on_retrieve_work
    fetcher, capsule = build_fetcher(%W[#{@qname} #{@other}])
    @pool.with do |c|
      c.call('LPUSH', @rqname, 'paused-payload')
      c.call('LPUSH', @rotherq, 'live-payload')
    end
    Wurk::Queue.new(@qname).pause!

    uow = fetcher.retrieve_work

    refute_nil uow
    assert_equal @rotherq, uow.queue
    assert_equal 'live-payload', uow.job
  ensure
    capsule&.stop
  end

  def test_fetcher_resumes_paused_queue_after_unpause
    fetcher, capsule = build_fetcher(%W[#{@qname}])
    @pool.with { |c| c.call('LPUSH', @rqname, 'job-1') }
    q = Wurk::Queue.new(@qname)
    q.pause!

    assert_empty fetcher.queues_cmd

    q.unpause!

    assert_includes fetcher.queues_cmd, @rqname
  ensure
    capsule&.stop
  end

  # --- fetch-path paused cache ----------------------------------------

  # The fast path has to be "no SMEMBERS at all", not "no SMEMBERS only once
  # something is paused": an empty `paused` SET is the state of virtually every
  # install, and re-confirming it once per fetch is the round trip per job the
  # cache exists to delete.
  def test_empty_paused_set_is_read_once_per_ttl_not_once_per_pass
    fetcher, capsule, counter = build_fetcher_with_paused_counter

    10.times { fetcher.queues_cmd }

    assert_equal 1, counter.count
  ensure
    capsule&.stop
  end

  def test_paused_set_stays_cached_while_a_queue_is_paused
    fetcher, capsule, counter = build_fetcher_with_paused_counter
    Wurk::Queue.new(@qname).pause!

    10.times { refute_includes fetcher.queues_cmd, @rqname }

    assert_equal 1, counter.count
  ensure
    capsule&.stop
  end

  # A host app that pauses a queue from inside a job has to see its own workers
  # stop, so a local pause expires the local copy rather than waiting out the
  # TTL. The cache is warmed first — without the invalidation this reads stale.
  def test_pause_in_this_process_expires_a_warm_cache_immediately
    fetcher, capsule = build_fetcher(%W[#{@qname} #{@other}])

    assert_includes fetcher.queues_cmd, @rqname

    Wurk::Queue.new(@qname).pause!

    refute_includes fetcher.queues_cmd, @rqname
  ensure
    capsule&.stop
  end

  def test_unpause_in_this_process_expires_a_warm_cache_immediately
    fetcher, capsule = build_fetcher(%W[#{@qname}])
    Wurk::Queue.new(@qname).pause!

    assert_empty fetcher.queues_cmd

    Wurk::Queue.new(@qname).unpause!

    assert_includes fetcher.queues_cmd, @rqname
  ensure
    capsule&.stop
  end

  # A worker runs one fetcher per capsule; a pause has to expire all of them,
  # not just whichever one happens to fetch next.
  def test_pause_expires_every_fetcher_in_this_process
    first, capsule_a = build_fetcher(%W[#{@qname}])
    second, capsule_b = build_fetcher(%W[#{@qname}])
    warm = [first.queues_cmd, second.queues_cmd]

    Wurk::Queue.new(@qname).pause!

    assert_equal [[@rqname], [@rqname]], warm
    assert_equal [[], []], [first.queues_cmd, second.queues_cmd]
  ensure
    capsule_a&.stop
    capsule_b&.stop
  end

  # Another process's pause is a bare SADD with no local invalidation — the
  # cross-process case the sign-off bounds at PAUSED_TTL instead of making
  # immediate.
  def test_pause_from_another_process_is_invisible_until_the_cache_expires
    fetcher, capsule = build_fetcher(%W[#{@qname}])

    assert_includes fetcher.queues_cmd, @rqname

    pause_elsewhere(@qname)

    assert_includes fetcher.queues_cmd, @rqname

    expire_cache(fetcher)

    assert_empty fetcher.queues_cmd
  ensure
    capsule&.stop
  end

  # The half a rewound deadline can't prove: that the deadline really is one
  # PAUSED_TTL out on the monotonic clock. With the test above, this pins "a
  # cross-process pause lands within 2 seconds" without spending 2 seconds.
  def test_cache_deadline_is_one_paused_ttl_out_on_the_monotonic_clock
    fetcher, capsule = build_fetcher(%W[#{@qname}])
    opened = monotonic_now
    fetcher.queues_cmd
    deadline = fetcher.instance_variable_get(:@paused_expires_at)

    assert_operator deadline, :>=, opened + Wurk::Fetcher::Reliable::PAUSED_TTL
    assert_operator deadline, :<=, monotonic_now + Wurk::Fetcher::Reliable::PAUSED_TTL
  ensure
    capsule&.stop
  end

  # Reporting is never served from the fetch cache: the dashboard has to show
  # what Redis says right now, even mid-TTL.
  def test_paused_predicate_reads_redis_while_a_fetcher_cache_is_warm
    fetcher, capsule = build_fetcher(%W[#{@qname}])
    fetcher.queues_cmd
    pause_elsewhere(@qname)

    assert_predicate Wurk::Queue.new(@qname), :paused?
    assert_includes fetcher.queues_cmd, @rqname
  ensure
    capsule&.stop
  end

  private

  def build_fetcher(queues)
    config  = Wurk::Configuration.new
    capsule = Wurk::Capsule.new('test', config)
    capsule.queues = queues
    [Wurk::Fetcher::Reliable.new(capsule), capsule]
  end

  def paused_members
    @pool.with { |c| c.call('SMEMBERS', Wurk::Keys::PAUSED_SET) }
  end

  def clean_keys
    @pool.with do |c|
      c.call('SREM', Wurk::Keys::PAUSED_SET, @qname, @other)
      c.call('DEL', @rqname, @rotherq)
      private_q = Wurk::Fetcher::Reliable.private_queue_name(@rqname)
      private_other = Wurk::Fetcher::Reliable.private_queue_name(@rotherq)
      c.call('DEL', private_q, private_other)
    end
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def drain_for_one_second(fetcher)
    deadline = monotonic_now + 1.0
    results = []
    results << fetcher.retrieve_work while monotonic_now < deadline
    results
  end

  def build_paused_fetcher_with_counter
    fetcher, capsule = build_fetcher(%W[#{@qname} #{@other}])
    capsule.config.fetch_poll_interval = 0.05
    Wurk::Queue.new(@qname).pause!
    Wurk::Queue.new(@other).pause!
    counter = RedisCallCounter.new(capsule.redis_pool)
    capsule.instance_variable_set(:@redis_pool, counter)
    [fetcher, capsule, counter]
  end

  def build_fetcher_with_paused_counter
    fetcher, capsule = build_fetcher(%W[#{@qname} #{@other}])
    counter = PausedReadCounter.new(capsule.redis_pool)
    capsule.instance_variable_set(:@redis_pool, counter)
    [fetcher, capsule, counter]
  end

  # A pause written by some other process: the SET changes, this process's
  # fetcher caches don't hear about it.
  def pause_elsewhere(name)
    @pool.with { |c| c.call('SADD', Wurk::Keys::PAUSED_SET, name) }
  end

  # Ages a fetcher's cached copy past PAUSED_TTL without spending PAUSED_TTL of
  # wall clock doing it.
  def expire_cache(fetcher)
    fetcher.instance_variable_set(:@paused_expires_at, monotonic_now - 1)
  end

  # Delegating pool that counts checkouts (one per `config.redis` block),
  # swapped in for the capsule's real pool so a test can measure Redis round
  # trips without a global monkeypatch. Mirrors WebSearchTest::RoundTripCounter.
  class RedisCallCounter
    attr_reader :count

    def initialize(pool)
      @pool = pool
      @count = 0
    end

    def with(&)
      @count += 1
      @pool.with(&)
    end
  end

  # Same swap-in trick, counting a named command rather than checkouts: the
  # point of the paused cache is that `SMEMBERS paused` stops happening while
  # the fetch itself keeps happening, which a checkout count can't tell apart.
  class PausedReadCounter
    attr_reader :count

    def initialize(pool)
      @pool = pool
      @count = 0
    end

    def with
      @pool.with { |conn| yield Tap.new(conn, self) }
    end

    def record
      @count += 1
    end

    class Tap < SimpleDelegator
      def initialize(conn, counter)
        super(conn)
        @counter = counter
      end

      def call(*args, **, &)
        @counter.record if args.first == 'SMEMBERS' && args[1] == Wurk::Keys::PAUSED_SET
        __getobj__.call(*args, **, &)
      end
    end
  end
end
