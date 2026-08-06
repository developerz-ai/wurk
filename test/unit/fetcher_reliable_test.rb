# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::Fetcher::Reliable against real Redis. Each test owns a
# unique public queue and the matching per-process private list, so
# parallel runs don't collide.
class FetcherReliableTest < Wurk::Test::UnitCase
  parallelize_me!

  # Serializes the single test that mutates the process-global ENV['DYNO']
  # so it can't race with a parallel sibling reading the same variable.
  ENV_MUTEX = Mutex.new

  # Raised by #with_dead_redis in place of a real connection error, so a test
  # asserting the failure path can't accidentally pass on some other raise.
  class DeadRedis < StandardError; end

  # CommandSpy counts commands; the piggyback's whole point is round trips, so
  # this counts checkouts too — each of the fetch and flush paths spends exactly
  # one command or one pipeline per checkout.
  class TripCountingSpy < Wurk::Test::CommandSpy
    attr_reader :trips

    def initialize(pool)
      super
      @trips = 0
    end

    def with(&)
      @trips += 1
      super
    end
  end

  def setup
    super
    @queue_name   = "fr-#{Process.pid}:#{object_id}"
    @public_queue = "#{Wurk::Keys::QUEUE_PREFIX}#{@queue_name}"
    @config       = Wurk::Configuration.new
    @capsule      = Wurk::Capsule.new('test', @config)
    @capsule.queues = [@queue_name]
    @fetcher      = Wurk::Fetcher::Reliable.new(@capsule)
    @pool         = @capsule.redis_pool
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', @public_queue, private_queue)
    end
  ensure
    super
  end

  # --- retrieve_work --------------------------------------------------

  def test_retrieve_work_returns_unit_of_work_with_payload
    payload = enqueue('p1')
    uow = @fetcher.retrieve_work

    refute_nil uow
    assert_equal payload, uow.job
  end

  def test_retrieve_work_moves_job_from_public_to_private
    enqueue('p1')
    @fetcher.retrieve_work

    assert_equal 0, llen(@public_queue)
    assert_equal 1, llen(private_queue)
  end

  def test_unit_of_work_carries_public_queue_key_and_capsule
    enqueue('p1')
    uow = @fetcher.retrieve_work

    assert_equal @public_queue, uow.queue
    assert_equal @queue_name, uow.queue_name
    assert_same @capsule, uow.config
  end

  def test_retrieve_work_returns_nil_when_terminated
    @fetcher.terminate

    assert_nil @fetcher.retrieve_work
  end

  # Manager#quiet terminates the shared fetcher before it terminates the
  # processors; Processor#run loops on its own flag, so the short-circuit has to
  # pause or every processor spins for the width of that window.
  def test_retrieve_work_pauses_on_the_quieted_short_circuit
    @fetcher.terminate

    took = elapsed { assert_nil @fetcher.retrieve_work }

    assert_operator took, :>=, Wurk::Fetcher::Reliable::QUIET_PAUSE * 0.9
  end

  # Every queue paused → nothing to block on, so retrieve_work must back off a
  # poll interval itself. Returning instantly hot-loops Processor#run on passes
  # that can never return a job (upstream Sidekiq #4825).
  def test_retrieve_work_backs_off_a_poll_interval_when_no_queue_is_fetchable
    @config.fetch_poll_interval = 0.2
    Wurk::Queue.new(@queue_name).pause!

    assert_empty @fetcher.queues_cmd

    took = elapsed { assert_nil @fetcher.retrieve_work }

    assert_operator took, :>=, 0.18
  end

  # --- acknowledge / SIGKILL behavior ---------------------------------

  # The ACK is held, not sent: it rides the next fetch's pipeline. Until then
  # the payload stays in the private list, which is exactly the window a hard
  # kill can now hit — see docs/idea/parity-divergences.md.
  def test_acknowledge_holds_the_lrem_rather_than_spending_a_round_trip
    enqueue('ack-me')
    uow = @fetcher.retrieve_work
    uow.acknowledge

    assert_equal 1, llen(private_queue), 'the ACK must not take a round trip of its own'
  end

  def test_acknowledge_removes_job_from_private_list_once_flushed
    enqueue('ack-me')
    uow = @fetcher.retrieve_work
    uow.acknowledge
    @fetcher.flush_pending_acks

    assert_equal 0, llen(private_queue)
    assert_equal 0, llen(@public_queue)
  end

  # The headline of the piggyback: the next fetch retires the job just finished
  # and picks up the next one in the same pipeline.
  def test_the_held_ack_rides_the_next_fetch
    enqueue('j1')
    enqueue('j2')
    @fetcher.retrieve_work.acknowledge

    second = @fetcher.retrieve_work

    assert_equal [second.job], lrange(private_queue), 'only the job just fetched may still be private'
  end

  # "Exactly one LREM per job", pinned by a count rather than an eyeball: the
  # whole job costs one checkout carrying LREM + DEL (retiring the previous job)
  # + LMOVE (fetching the next). A held ACK re-sent on each queue of the walk,
  # or left in its slot after a successful send, shows up here.
  def test_a_job_costs_one_checkout_of_three_commands
    enqueue('j1')
    enqueue('j2')
    @fetcher.retrieve_work.tap { |uow| uow.jid = 'jid-1' }.acknowledge
    spy = install_command_spy

    @fetcher.retrieve_work

    assert_equal 1, spy.trips
    assert_equal 3, spy.count
  end

  def test_acknowledge_itself_issues_no_command
    enqueue('free-ack')
    uow = @fetcher.retrieve_work
    spy = install_command_spy

    uow.acknowledge

    assert_equal 0, spy.count
  end

  def test_unacked_job_survives_in_private_list_after_simulated_sigkill
    payload = enqueue('crash')
    @fetcher.retrieve_work
    # No acknowledge — equivalent to SIGKILL between fetch and ack.

    assert_equal 0, llen(@public_queue)
    assert_equal 1, llen(private_queue)
    assert_equal payload, lindex(private_queue, 0)
  end

  # The Processor fills in `jid` after parsing; the ACK then retires the job's
  # poison-pill recovery counter in the same round trip as the LREM, so a job
  # that completed can't be dead-set by a later reclaim (F6).
  def test_acknowledge_clears_the_poison_pill_counter_for_its_jid
    jid = "frj-#{Process.pid}-#{object_id}"
    counter = Wurk::Middleware::PoisonPill.counter_key(jid)
    @pool.with { |c| c.call('SET', counter, '2') }
    enqueue('ack-recovered')
    uow = @fetcher.retrieve_work
    uow.jid = jid
    uow.acknowledge
    @fetcher.flush_pending_acks

    assert_equal 0, llen(private_queue), 'the ACK still removes the job from the private list'
    assert_equal 0, Wurk::Middleware::PoisonPill.recovery_count(jid)
  end

  # No jid (a payload the Processor could not parse, or a fetcher that never
  # sets one) → plain LREM, no DEL riding along.
  def test_acknowledge_without_a_jid_only_lrems
    enqueue('ack-plain')
    uow = @fetcher.retrieve_work

    assert_nil uow.jid

    uow.acknowledge
    spy = install_command_spy
    @fetcher.flush_pending_acks

    assert_equal 1, spy.count
    assert_equal 0, llen(private_queue)
  end

  # A blank jid must not DEL the bare `super_fetch:recovered:` prefix — that
  # key belongs to no job and deleting it would be a silent wrong-key write.
  def test_acknowledge_with_blank_jid_leaves_the_prefix_key_alone
    prefix = Wurk::Middleware::PoisonPill::KEY_PREFIX
    @pool.with { |c| c.call('SET', prefix, 'sentinel') }
    enqueue('ack-blank-jid')
    uow = @fetcher.retrieve_work
    uow.jid = ''
    uow.acknowledge
    @fetcher.flush_pending_acks

    assert_equal 0, llen(private_queue)
    assert_equal('sentinel', @pool.with { |c| c.call('GET', prefix) })
  end

  # --- flush points ---------------------------------------------------

  # A blocking BLMOVE can't join a pipeline, so an ACK still held when the walk
  # comes up empty would sit for a whole poll interval. The walk sends it on the
  # way past: the pipeline that finds nothing to LMOVE still carries the LREM.
  def test_a_held_ack_is_sent_before_the_fetcher_blocks
    @config.fetch_poll_interval = 0.05
    enqueue('last')
    @fetcher.retrieve_work.acknowledge

    assert_nil @fetcher.retrieve_work, 'precondition: an empty queue, so this falls through to BLMOVE'
    assert_equal 0, llen(private_queue)
  end

  # Every served queue paused: the walk never runs, so the early return has to
  # send the held ACK itself.
  def test_a_held_ack_is_sent_when_no_queue_is_fetchable
    @config.fetch_poll_interval = 0.05
    enqueue('paused-after')
    @fetcher.retrieve_work.acknowledge
    Wurk::Queue.new(@queue_name).pause!

    assert_nil @fetcher.retrieve_work
    assert_equal 0, llen(private_queue)
  end

  # Quiet is one-way: after it retrieve_work short-circuits forever, so an ACK
  # held at that point would sit until shutdown.
  def test_terminate_sends_held_acks
    enqueue('quiet-me')
    @fetcher.retrieve_work.acknowledge

    @fetcher.terminate

    assert_equal 0, llen(private_queue)
  end

  # ...and the short-circuit sends one deferred after quiet, for the processor
  # that finishes its last job in that window and loops once more.
  def test_the_quieted_short_circuit_sends_held_acks
    enqueue('quiet-then-ack')
    uow = @fetcher.retrieve_work
    @fetcher.terminate
    uow.acknowledge

    assert_nil @fetcher.retrieve_work
    assert_equal 0, llen(private_queue)
  end

  # A Redis failure on the quiet path must not escape: Manager#quiet has no
  # rescue, and a raise there skips the rest of the drain. The ACK stays held
  # for the next flush point instead.
  def test_terminate_reports_a_failed_flush_instead_of_raising
    errors = []
    @config.error_handlers.replace([->(ex, _ctx, _cfg) { errors << ex }])
    enqueue('quiet-blip')
    @fetcher.retrieve_work.acknowledge
    with_dead_redis { @fetcher.terminate }

    assert_equal 1, errors.size
    assert_equal 1, llen(private_queue), 'the ACK must survive a failed quiet flush'
  end

  # An idle fetcher must not spend a round trip announcing it has nothing to ACK.
  def test_flushing_with_nothing_held_costs_no_round_trip
    spy = install_command_spy

    assert_nil @fetcher.flush_pending_acks
    assert_equal 0, spy.count
  end

  # A transient failure must not eat the ACK — an LREM that is never sent leaves
  # a finished job for the next boot's reaper to run again.
  def test_a_failed_flush_keeps_the_acks_it_could_not_send
    enqueue('flush-blip')
    @fetcher.retrieve_work.acknowledge

    with_dead_redis { assert_raises(DeadRedis) { @fetcher.flush_pending_acks } }
    @fetcher.flush_pending_acks

    assert_equal 0, llen(private_queue)
  end

  # Same contract on the piggybacked copy: the walk takes the ACK out of its
  # slot before it sends it, so a fetch that blows up has to hand it back.
  # `queues_cmd` is warmed first so the failure lands on the LMOVE, not on the
  # paused-set read ahead of it.
  def test_a_failed_fetch_hands_the_held_ack_back
    enqueue('fetch-blip')
    @fetcher.retrieve_work.acknowledge
    @fetcher.queues_cmd

    with_dead_redis { assert_raises(DeadRedis) { @fetcher.retrieve_work } }
    @fetcher.flush_pending_acks

    assert_equal 0, llen(private_queue)
  end

  # One fetcher is shared by every processor thread, so a held ACK belongs to
  # the thread that finished the job: another thread's fetch must not send it
  # (it would be paying for work it isn't doing, and the owning thread would
  # then send it again). A flush, unlike a fetch, drains every thread's slot.
  def test_a_held_ack_belongs_to_the_thread_that_finished_the_job
    enqueue('j1')
    enqueue('j2')
    held = Thread.new { @fetcher.retrieve_work.tap(&:acknowledge).job }.value

    @fetcher.retrieve_work

    assert_includes lrange(private_queue), held, "another thread's fetch must not send it"

    @fetcher.flush_pending_acks

    refute_includes lrange(private_queue), held, 'a flush drains every thread'
  end

  # --- requeue (single) ----------------------------------------------

  def test_requeue_pushes_back_to_public_queue
    payload = enqueue('req')
    uow = @fetcher.retrieve_work
    uow.acknowledge
    uow.requeue

    assert_equal payload, lindex(@public_queue, 0)
  end

  # --- bulk_requeue (atomic private→public move) ---------------------

  # The reliable-fetch recovery path: a job still in the private list at
  # shutdown is LREM'd out and RPUSH'd to its public queue in one atomic hop,
  # so it lands in exactly one place — no private+public double copy that
  # would double-execute (once from the RPUSH, once from the boot reaper).
  def test_bulk_requeue_moves_job_from_private_to_public
    payload = enqueue('bq1')
    uow = @fetcher.retrieve_work

    @fetcher.bulk_requeue([uow])

    assert_equal 0, llen(private_queue), 'LREM must clear the private copy'
    assert_equal [payload], lrange(@public_queue)
  end

  # hard_shutdown reads `job` off another thread, so a Processor can ACK
  # between that read and the requeue — and a held ACK is invisible to it, so
  # without the flush the requeue Lua's LREM guard would still find the payload
  # in the private list and RPUSH a finished job back onto the public queue.
  # That would re-run the last job of every busy processor on every graceful
  # shutdown, which is the reversal trigger in the slice-02 sign-off.
  def test_bulk_requeue_sends_held_acks_before_it_requeues
    enqueue('bq-acked')
    uow = @fetcher.retrieve_work
    uow.acknowledge

    @fetcher.bulk_requeue([uow])

    assert_equal 0, llen(private_queue)
    assert_equal 0, llen(@public_queue), 'a finished job must not be re-pushed'
  end

  # The flush is unconditional: a processor that finished its last job holds an
  # ACK even when nothing is left in flight to requeue.
  def test_bulk_requeue_sends_held_acks_with_nothing_in_flight
    enqueue('bq-nothing-inflight')
    @fetcher.retrieve_work.acknowledge

    assert_nil @fetcher.bulk_requeue([])
    assert_equal 0, llen(private_queue)
  end

  def test_bulk_requeue_moves_each_uow_to_its_own_queue
    other_queue_name   = "#{@queue_name}-other"
    other_public_queue = "#{Wurk::Keys::QUEUE_PREFIX}#{other_queue_name}"
    other_private      = Wurk::Fetcher::Reliable.private_queue_name(other_public_queue)
    seed_private(private_queue, 'j1', 'j2')
    seed_private(other_private, 'k1')
    uows = [
      uow_for(@public_queue, 'j1'),
      uow_for(@public_queue, 'j2'),
      uow_for(other_public_queue, 'k1')
    ]

    @fetcher.bulk_requeue(uows)

    assert_equal %w[j1 j2], lrange(@public_queue)
    assert_equal %w[k1], lrange(other_public_queue)
  ensure
    @pool.with { |c| c.call('DEL', other_public_queue, other_private) } if other_public_queue
  end

  def test_bulk_requeue_noop_on_nil
    assert_nil @fetcher.bulk_requeue(nil)
  end

  def test_bulk_requeue_noop_on_empty
    assert_nil @fetcher.bulk_requeue([])
  end

  # NOSCRIPT recovery (rescue branch): a pipelined EVALSHA surfaces NOSCRIPT
  # only at finalize, so requeue_pipelined reloads all scripts and replays via
  # source-embedded EVAL. SCRIPT FLUSH forces that path; the move must still land.
  def test_bulk_requeue_reloads_lua_after_script_flush
    payload = enqueue('bq-flush')
    uow = @fetcher.retrieve_work
    @pool.with { |c| c.call('SCRIPT', 'FLUSH') }

    @fetcher.bulk_requeue([uow])

    assert_equal [payload], lrange(@public_queue),
                 'NOSCRIPT must trigger script_load_all + EVAL-source retry, then move the job'
  end

  # Re-raise branch: a string at the private-list key makes the RELIABLE_REQUEUE
  # Lua's LREM raise WRONGTYPE — a CommandError that is *not* NOSCRIPT, so it
  # must propagate rather than trigger the script-reload retry.
  def test_bulk_requeue_reraises_non_noscript_command_error
    @pool.with { |c| c.call('SET', private_queue, 'not-a-list') }
    uow = uow_for(@public_queue, 'x1')

    assert_raises(RedisClient::CommandError) { @fetcher.bulk_requeue([uow]) }
  end

  # --- queues_cmd ----------------------------------------------------

  def test_queues_cmd_strict_preserves_declaration_order
    @capsule.queues = %w[high default low]

    assert_equal %w[queue:high queue:default queue:low], @fetcher.queues_cmd
  end

  def test_queues_cmd_random_returns_uniq_set_and_shuffles
    @capsule.queues = %w[a,1 b,1 c,1]

    sets = Array.new(30) { @fetcher.queues_cmd }

    sets.each { |s| assert_equal %w[queue:a queue:b queue:c].sort, s.sort }
    refute_equal 1, sets.map(&:join).uniq.size, 'expected at least two distinct orderings across 30 calls'
  end

  def test_queues_cmd_weighted_shuffles_and_dedupes
    @capsule.queues = %w[hot,3 cold,1]

    # Capsule pre-expands to ["hot","hot","hot","cold"]; queues_cmd shuffles
    # then dedupes for the BLMOVE iteration (we can't BLMOVE the same key
    # twice in one fetch pass).
    @fetcher.queues_cmd.each { |q| assert_includes %w[queue:hot queue:cold], q }
  end

  # --- private queue naming -----------------------------------------

  def test_private_queue_name_uses_pipe_separators_and_encodes_identity
    parts = Wurk::Fetcher::Reliable.private_queue_name(@public_queue).split('|')

    # [public_queue, hostname, pid, nonce, index] — assert as a single tuple so
    # the whole shape is one expectation rather than five.
    assert_equal [@public_queue, parts[1], Process.pid.to_s, Wurk::Component::PROCESS_NONCE, '0'], parts
  end

  # The nonce is what distinguishes two incarnations that share host+pid (a
  # container restarted into a fresh PID namespace), so it must be the
  # process-wide one the heartbeat publishes in `identity`, not a fresh value
  # per call.
  def test_private_queue_name_carries_the_process_nonce_from_identity
    nonce = Wurk::Fetcher::Reliable.private_queue_name(@public_queue).split('|')[3]

    assert_equal @fetcher.identity.split(':').last, nonce
    assert_equal nonce, Wurk::Fetcher::Reliable.private_queue_name(@public_queue).split('|')[3]
  end

  def test_private_queue_name_honors_dyno_env_when_set
    ENV_MUTEX.synchronize do
      original = ENV.fetch('DYNO', nil)
      ENV['DYNO'] = 'web.42'
      name = Wurk::Fetcher::Reliable.private_queue_name(@public_queue)

      assert_equal 'web.42', name.split('|')[1]
    ensure
      ENV['DYNO'] = original
    end
  end

  # --- fetch_poll_interval (Pro super_fetch §3.3) -----------------------

  # An empty poll blocks on BLMOVE for TIMEOUT (2s) by default.
  def test_blmove_block_timeout_defaults_to_timeout
    args = captured_blmove_args
    @fetcher.send(:blmove, @public_queue)
    t = Wurk::Fetcher::Reliable::TIMEOUT

    assert_equal [t + 1, 'BLMOVE', @public_queue, private_queue, 'RIGHT', 'LEFT', t], args
  end

  # config.fetch_poll_interval overrides the block timeout (and the socket
  # read-timeout stays one second past it).
  def test_blmove_honors_config_fetch_poll_interval
    @config.fetch_poll_interval = 0.25
    args = captured_blmove_args
    @fetcher.send(:blmove, @public_queue)

    assert_equal [1.25, 'BLMOVE', @public_queue, private_queue, 'RIGHT', 'LEFT', 0.25], args
  end

  # blmove must draw from the dedicated fetch pool, never the main pool, so a
  # parked BLMOVE can't starve the background loops that share the main pool (#101).
  def test_blmove_checks_out_from_the_fetch_pool_not_the_main_pool
    used = nil
    conn = Object.new
    conn.define_singleton_method(:blocking_call) { |*_| nil }
    @capsule.define_singleton_method(:fetch_redis) do |**_opts, &blk|
      used = :fetch
      blk.call(conn)
    end
    @capsule.define_singleton_method(:redis) do |**_opts, &blk|
      used = :main
      blk.call(conn)
    end

    @fetcher.send(:blmove, @public_queue)

    assert_equal :fetch, used
  end

  private

  # Stub the capsule's fetch pool so blmove's BLMOVE timeout args can be
  # captured without actually blocking on a real empty queue. Returns the array
  # the recorded `blocking_call` writes its arguments into.
  def captured_blmove_args
    box = []
    conn = Object.new
    conn.define_singleton_method(:blocking_call) do |*a|
      box.replace(a)
      nil
    end
    @capsule.define_singleton_method(:fetch_redis) { |**_opts, &blk| blk.call(conn) }
    box
  end

  # Points the capsule's main pool at a counting stand-in. PoolCheckout falls
  # through to `pool.with` for anything that isn't a RedisPool, so the fetcher's
  # `idempotent: true` claims resolve here unchanged.
  def install_command_spy
    spy = TripCountingSpy.new(@pool)
    @capsule.define_singleton_method(:redis_pool) { spy }
    spy
  end

  # Runs the block with every main-pool checkout raising, then restores the real
  # pool so the assertions that follow can read Redis.
  def with_dead_redis
    @capsule.define_singleton_method(:redis) { |**_opts, &_blk| raise DeadRedis }
    yield
  ensure
    @capsule.singleton_class.remove_method(:redis)
  end

  # Monotonic wall-clock cost of the block, in seconds.
  def elapsed
    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    yield
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started
  end

  def private_queue
    Wurk::Fetcher::Reliable.private_queue_name(@public_queue)
  end

  def enqueue(payload)
    @pool.with { |c| c.call('LPUSH', @public_queue, payload) }
    payload
  end

  # Place payloads into a private list exactly as a real fetch's LMOVE would,
  # so bulk_requeue's LREM guard has a copy to remove.
  def seed_private(key, *payloads)
    @pool.with { |c| c.call('RPUSH', key, *payloads) }
  end

  def llen(key)
    @pool.with { |c| c.call('LLEN', key) }
  end

  def lrange(key)
    @pool.with { |c| c.call('LRANGE', key, 0, -1) }
  end

  def lindex(key, idx)
    @pool.with { |c| c.call('LINDEX', key, idx) }
  end

  def uow_for(public_queue, payload)
    Wurk::Fetcher::Reliable::UnitOfWork.new(queue: public_queue, job: payload, config: @capsule, fetcher: @fetcher)
  end
end
