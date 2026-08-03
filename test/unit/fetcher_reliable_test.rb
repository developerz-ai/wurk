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
  # poll interval itself. Returning instantly hot-loops Processor#run and pays
  # an SMEMBERS of the paused set on every pass (upstream Sidekiq #4825).
  def test_retrieve_work_backs_off_a_poll_interval_when_no_queue_is_fetchable
    @config.fetch_poll_interval = 0.2
    Wurk::Queue.new(@queue_name).pause!

    assert_empty @fetcher.queues_cmd

    took = elapsed { assert_nil @fetcher.retrieve_work }

    assert_operator took, :>=, 0.18
  end

  # --- acknowledge / SIGKILL behavior ---------------------------------

  def test_acknowledge_removes_job_from_private_list
    enqueue('ack-me')
    uow = @fetcher.retrieve_work
    uow.acknowledge

    assert_equal 0, llen(private_queue)
    assert_equal 0, llen(@public_queue)
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

    assert_equal 0, llen(private_queue)
    assert_equal('sentinel', @pool.with { |c| c.call('GET', prefix) })
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
  # (LREM the private copy) between that read and the requeue. The LREM guard
  # then removes nothing and skips the RPUSH — a job that already finished is
  # not resurrected onto the public queue.
  def test_bulk_requeue_skips_rpush_when_job_already_acked
    enqueue('bq-acked')
    uow = @fetcher.retrieve_work
    uow.acknowledge

    @fetcher.bulk_requeue([uow])

    assert_equal 0, llen(private_queue)
    assert_equal 0, llen(@public_queue), 'acked job must not be re-pushed'
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
    Wurk::Fetcher::Reliable::UnitOfWork.new(queue: public_queue, job: payload, config: @capsule)
  end
end
