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

  # --- requeue (single) ----------------------------------------------

  def test_requeue_pushes_back_to_public_queue
    payload = enqueue('req')
    uow = @fetcher.retrieve_work
    uow.acknowledge
    uow.requeue

    assert_equal payload, lindex(@public_queue, 0)
  end

  # --- bulk_requeue --------------------------------------------------

  def test_bulk_requeue_rpushes_grouped_by_queue
    other_queue_name   = "#{@queue_name}-other"
    other_public_queue = "#{Wurk::Keys::QUEUE_PREFIX}#{other_queue_name}"
    uows = [
      uow_for(@public_queue, 'j1'),
      uow_for(@public_queue, 'j2'),
      uow_for(other_public_queue, 'k1')
    ]

    @fetcher.bulk_requeue(uows)

    assert_equal %w[j1 j2], lrange(@public_queue)
    assert_equal %w[k1], lrange(other_public_queue)
  ensure
    @pool.with { |c| c.call('DEL', other_public_queue) } if other_public_queue
  end

  def test_bulk_requeue_noop_on_nil
    assert_nil @fetcher.bulk_requeue(nil)
  end

  def test_bulk_requeue_noop_on_empty
    assert_nil @fetcher.bulk_requeue([])
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

    # [public_queue, hostname, pid, index] — assert as a single tuple so the
    # whole shape is one expectation rather than four.
    assert_equal [@public_queue, parts[1], Process.pid.to_s, '0'], parts
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

  private

  # Stub the capsule's Redis so blmove's BLMOVE timeout args can be captured
  # without actually blocking on a real empty queue. Returns the array the
  # recorded `blocking_call` writes its arguments into.
  def captured_blmove_args
    box = []
    conn = Object.new
    conn.define_singleton_method(:blocking_call) do |*a|
      box.replace(a)
      nil
    end
    @capsule.define_singleton_method(:redis) { |&blk| blk.call(conn) }
    box
  end

  def private_queue
    Wurk::Fetcher::Reliable.private_queue_name(@public_queue)
  end

  def enqueue(payload)
    @pool.with { |c| c.call('LPUSH', @public_queue, payload) }
    payload
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
