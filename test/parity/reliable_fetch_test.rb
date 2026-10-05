# frozen_string_literal: true

require_relative '../test_helper'

# Parity oracle for reliable fetch — the observable half of Pro's super_fetch
# contract, driven through the `Sidekiq::BasicFetch` drop-in name (Wurk aliases
# it to its reliable fetcher, see below).
#
# Spec: docs/target/sidekiq-pro.md §3.2 (atomic move public tail → private
# list; the job stays parked until acknowledged; a dead process's parked jobs
# go back to their public queue; poison pill at `super_fetch:recovered:<jid>`,
# 72h window), §6 (paused queues are skipped), §12 (poison-pill key + TTL);
# docs/target/sidekiq-free.md §15 (UnitOfWork#queue / #queue_name / #requeue,
# bulk_requeue RPUSHes back to the fetch end) and §31 gotchas 4, 11.
#
# Documented divergences honoured (docs/idea/parity-divergences.md):
#   * Reliable fetch is the only mode — BasicFetch is the reliable fetcher, so
#     a fetched job is never in zero lists.
#   * The ACK is deferred onto the next fetch; it is asserted only after one of
#     the documented flush points (next fetch, terminate, bulk_requeue).
#   * bulk_requeue moves still-parked jobs private → public immediately.
#   * Orphan reclaim pushes with `LMOVE … RIGHT RIGHT`; the position a reclaimed
#     job takes in the public queue is therefore not asserted, only that it is
#     back exactly once.
# Private-list key names are an implementation detail; jobs are located by
# scanning every list in the (per-worker, flushed) DB.
class ReliableFetchParityTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL = 0.2

  def setup
    super
    @q = "rfetch-#{Process.pid}-#{object_id}"
    @configs = []
  end

  def teardown
    @configs.each { |c| c.redis_pool.shutdown(&:close) if c.redis_pool.respond_to?(:shutdown) }
  rescue StandardError
    nil
  ensure
    super
  end

  # --- fetch -------------------------------------------------------------------

  def test_fetch_returns_the_exact_payload_and_parks_it_out_of_the_public_queue
    job = push(@q, 1)
    uow = fetcher(@q).retrieve_work

    refute_nil uow
    assert_equal job, uow.job, 'the unit of work carries the exact stored bytes'
    assert_equal @q, uow.queue_name
    assert_equal "queue:#{@q}", uow.queue
    assert_equal 0, redis('LLEN', "queue:#{@q}"), 'a fetched job leaves the public queue'
    assert_equal 0, Sidekiq::Queue.new(@q).size
    assert_equal 1, copies(job).size, 'and lives in exactly one other list until acked'
    refute_equal "queue:#{@q}", copies(job).first
  end

  def test_fetched_job_is_invisible_to_other_fetchers
    push(@q, 1)

    refute_nil fetcher(@q).retrieve_work
    assert_nil fetcher(@q).retrieve_work, 'a second process must not see an in-flight job'
  end

  def test_fetch_is_fifo
    3.times { |i| push(@q, i) }
    f = fetcher(@q)

    assert_equal [[0], [1], [2]], Array.new(3) { Wurk.load_json(f.retrieve_work.job)['args'] }
  end

  def test_empty_queue_returns_nil
    assert_nil fetcher(@q).retrieve_work
  end

  def test_strict_mode_drains_queues_in_declared_order
    high = "#{@q}-high"
    low = "#{@q}-low"
    push(low, 'low')
    push(high, 'high')
    f = fetcher(high, low)

    assert_equal high, f.retrieve_work.queue_name
    assert_equal low, f.retrieve_work.queue_name
  end

  def test_paused_queue_is_skipped_until_unpaused
    other = "#{@q}-other"
    push(@q, 'paused')
    queue = Sidekiq::Queue.new(@q)
    queue.pause!
    f = fetcher(@q, other)

    assert_nil f.retrieve_work, 'a paused queue is never fetched'
    assert_equal 1, queue.size, 'its jobs stay put'

    queue.unpause!

    assert_equal @q, f.retrieve_work&.queue_name
  end

  # --- acknowledge -------------------------------------------------------------

  def test_acknowledged_job_is_gone_after_the_next_fetch
    job = push(@q, 1)
    f = fetcher(@q)
    f.retrieve_work.acknowledge

    assert_nil f.retrieve_work
    assert_empty copies(job), 'an acked job is removed from every list'
  end

  def test_acknowledged_job_is_gone_after_terminate
    job = push(@q, 1)
    f = fetcher(@q)
    f.retrieve_work.acknowledge
    f.terminate

    assert_empty copies(job)
  end

  def test_ack_removes_only_its_own_job
    a = push(@q, 'a')
    b = push(@q, 'b')
    f = fetcher(@q)
    f.retrieve_work.acknowledge
    f.retrieve_work
    f.terminate

    assert_empty copies(a)
    assert_equal 1, copies(b).size, 'the un-acked job stays parked'
  end

  def test_acking_one_of_two_identical_payloads_keeps_the_other
    job = push(@q, 'same', jid: 'c' * 24)
    redis('LPUSH', "queue:#{@q}", job)
    f = fetcher(@q)
    first = f.retrieve_work
    f.retrieve_work
    first.acknowledge
    f.terminate

    assert_equal 1, copies(job).size, 'ack removes one occurrence, not every byte-identical copy'
  end

  # --- requeue -----------------------------------------------------------------

  def test_requeue_returns_the_job_to_the_fetch_end_of_its_queue
    push(@q, 'a')
    push(@q, 'b')
    f = fetcher(@q)
    uow = f.retrieve_work
    uow.requeue

    assert_equal 2, redis('LLEN', "queue:#{@q}")
    assert_equal uow.job, redis('LINDEX', "queue:#{@q}", -1), 'requeue RPUSHes: next to be fetched'
    assert_equal ["queue:#{@q}"], copies(uow.job), 'and no longer parked'
    assert_equal uow.job, f.retrieve_work.job
  end

  def test_bulk_requeue_returns_every_in_progress_job_once
    other = "#{@q}-b"
    push(@q, 'a1')
    push(@q, 'a2')
    push(other, 'b1')
    f = fetcher(@q, other)
    in_progress = Array.new(3) { f.retrieve_work }

    f.bulk_requeue(in_progress)

    in_progress.each do |uow|
      assert_equal [uow.queue], copies(uow.job), "#{uow.job} is back in its own public queue exactly once"
    end
    assert_equal 2, redis('LLEN', "queue:#{@q}")
    assert_equal 1, redis('LLEN', "queue:#{other}")
  end

  def test_bulk_requeue_puts_jobs_at_the_fetch_end
    push(@q, 'first')
    push(@q, 'waiting')
    f = fetcher(@q)
    uow = f.retrieve_work

    f.bulk_requeue([uow])

    assert_equal uow.job, redis('LINDEX', "queue:#{@q}", -1), 'interrupted work runs before waiting work'
  end

  def test_bulk_requeue_never_resurrects_an_acknowledged_job
    a = push(@q, 'a')
    push(@q, 'b')
    f = fetcher(@q)
    done = f.retrieve_work
    live = f.retrieve_work
    done.acknowledge

    f.bulk_requeue([done, live])

    assert_empty copies(a), 'an acked job is not requeued even if handed to bulk_requeue'
    assert_equal ["queue:#{@q}"], copies(live.job)
  end

  def test_bulk_requeue_with_nothing_in_progress_is_a_noop
    push(@q, 'idle')
    f = fetcher(@q)
    f.bulk_requeue([])

    assert_equal 1, redis('LLEN', "queue:#{@q}")
  end

  # --- orphan recovery (Pro §3.2) ----------------------------------------------

  def test_killed_process_in_flight_job_is_recovered_exactly_once
    job = push(@q, 'orphan')
    fetch_and_die(@q)

    assert_equal 0, redis('LLEN', "queue:#{@q}"), 'a SIGKILLed worker leaves its job parked, not lost'
    assert_equal 1, copies(job).size

    assert_equal 1, reaper.reclaim_full!
    assert_equal ["queue:#{@q}"], copies(job), 'recovered into its public queue, exactly once'

    assert_equal 0, reaper.reclaim_full!, 'a second sweep finds nothing to recover'
    assert_equal 1, redis('LLEN', "queue:#{@q}")
  end

  def test_recovered_job_is_fetchable_again
    job = push(@q, 'orphan')
    fetch_and_die(@q)
    reaper.reclaim_full!

    assert_equal job, fetcher(@q).retrieve_work&.job
  end

  def test_live_process_in_flight_job_is_not_reclaimed
    job = push(@q, 'mine')
    uow = fetcher(@q).retrieve_work

    assert_equal 0, reaper.reclaim_full!
    refute_includes copies(job), "queue:#{@q}", 'a live worker keeps its in-flight job'
    assert_equal job, uow.job
  end

  def test_recovery_records_the_poison_pill_counter_with_a_72h_window
    job = push(@q, 'orphan')
    jid = Wurk.load_json(job)['jid']
    fetch_and_die(@q)
    reaper.reclaim_full!

    key = "super_fetch:recovered:#{jid}"

    assert_equal 1, redis('EXISTS', key), 'Pro §12: counter lives at super_fetch:recovered:<jid>'
    ttl = redis('TTL', key)

    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, 72 * 3600
  end

  def test_a_job_that_keeps_killing_its_worker_ends_in_the_dead_set
    job = push(@q, 'poison')
    jid = Wurk.load_json(job)['jid']
    crashes = 0

    6.times do
      break if redis('LLEN', "queue:#{@q}").zero? && crashes.positive?

      fetch_and_die(@q)
      crashes += 1
      reaper.reclaim_full!
    end

    assert_equal 0, redis('LLEN', "queue:#{@q}"), 'a poison pill is not requeued forever'
    assert_empty copies(job), 'and is not left parked'
    dead = redis('ZRANGE', 'dead', 0, -1).map { |m| Wurk.load_json(m)['jid'] }

    assert_equal [jid], dead, 'it is killed into the dead set exactly once'
    assert_operator crashes, :>, 1, 'the first recovery requeues rather than kills'
    assert_equal 4, crashes, 'three recoveries, then the fourth orphaning kills'
  end

  # super_fetch's recover_orphan script INCRs the counter and requeues while
  # `count <= max_recoveries` (3), killing only when the count reaches 4: three
  # recoveries, then the fourth orphaning dead-sets the job ("an orphan
  # recovered ≥ 3 times … is killed").
  def test_poison_pill_allows_three_recoveries_and_kills_on_the_fourth_orphaning
    job = push(@q, 'poison')
    3.times do |i|
      fetch_and_die(@q)
      reaper.reclaim_full!

      assert_equal ["queue:#{@q}"], copies(job), "recovery #{i + 1} requeues"
    end
    fetch_and_die(@q)
    reaper.reclaim_full!

    assert_empty copies(job)
    assert_equal 1, redis('ZCARD', 'dead')
  end

  private

  def redis(*cmd)
    Wurk.redis { |c| c.call(*cmd) }
  end

  def push(queue, arg, jid: nil)
    item = { 'class' => 'RfJob', 'args' => [arg], 'queue' => queue }
    item['jid'] = jid if jid
    Sidekiq::Client.push(item)
    redis('LINDEX', "queue:#{queue}", 0)
  end

  def new_config(*queues)
    config = Sidekiq::Config.new
    config.fetch_poll_interval = POLL
    config.logger = Logger.new(IO::NULL)
    config.capsule("rf#{object_id}") do |cap|
      cap.queues = queues
      cap.concurrency = 1
    end
    config
  end

  def fetcher(*queues)
    config = new_config(*queues)
    @configs << config
    Sidekiq::BasicFetch.new(config.capsules.values.last)
  end

  def reaper
    config = new_config(@q)
    @configs << config
    Wurk::Fetcher::Reaper.new(config, grace: 0)
  end

  # Every list key holding a byte-identical copy of `job`, one entry per copy.
  def copies(job)
    lists = []
    cursor = '0'
    loop do
      cursor, keys = redis('SCAN', cursor, 'TYPE', 'list', 'COUNT', 1000)
      lists.concat(keys)
      break if cursor == '0'
    end
    lists.flat_map { |key| [key] * redis('LRANGE', key, 0, -1).count(job) }
  end

  # A real process fetches one job and is SIGKILLed mid-flight: no ack, no
  # requeue, no at_exit. Its Redis pool is built after the fork.
  def fetch_and_die(queue)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      uow = fetcher(queue).retrieve_work
      writer.write(uow ? 'fetched' : 'empty')
      writer.close
      ::Process.kill(:KILL, ::Process.pid)
    end
    writer.close
    result = reader.read
    ::Process.wait(pid)

    assert_equal 'fetched', result, 'the doomed worker must have claimed the job'
  ensure
    reader&.close
  end
end
