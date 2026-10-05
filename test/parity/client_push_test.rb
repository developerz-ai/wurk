# frozen_string_literal: true

require_relative '../test_helper'
require 'active_job'
require 'active_job/queue_adapters/wurk_adapter'

ActiveJob::Base.logger = Logger.new(IO::NULL)

# Parity oracle for the enqueue wire format: what `Sidekiq::Client#push`,
# `#push_bulk` and the `Sidekiq::Job` push DSL write to Redis.
#
# Spec: docs/target/sidekiq-free.md §1.1 (queues SET + queue lists), §1.2
# (schedule ZSET, score = epoch float seconds), §2 (job payload: field names,
# types, units), §6 (push DSL), §7 / §7.1 / §7.2 (push, atomic_push,
# push_bulk options), §9 (JobUtil validate / verify_json / normalize_item),
# §28 (ActiveJob wrapper payload), §31 gotchas 1-5, 15.
#
# Upstream revision: test/parity/.sidekiq_sha (Sidekiq 8.1: `created_at` and
# `enqueued_at` are Integer epoch MILLISECONDS; `at` and ZSET scores stay Float
# epoch SECONDS). Erratum, not a divergence: §28 names the wrapper class
# `ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper`; Sidekiq 8.1 makes that
# an alias of `Sidekiq::ActiveJob::Wrapper`, and the String written to `class`
# is the alias target's name, so that is what is asserted here.
class ClientPushParityTest < Wurk::Test::UnitCase
  parallelize_me!

  JID = /\A[0-9a-f]{24}\z/
  PLAIN_KEYS = %w[args class created_at enqueued_at jid queue retry].freeze

  class PlainJob
    include Sidekiq::Job

    def perform(*); end
  end

  class OptionedJob
    include Sidekiq::Job

    sidekiq_options queue: 'optioned-q', retry: 5, backtrace: 3

    def perform(*); end
  end

  class NotAJob; end

  class HaltOddArgs
    def call(_klass, job, _queue, _pool)
      yield unless job['args'].first.to_i.odd?
    end
  end

  def setup
    super
    @queue = "cpush-#{Process.pid}-#{object_id}"
    @before_keys = redis('KEYS', '*')
  end

  # --- push: payload shape ---------------------------------------------------

  def test_push_writes_canonical_payload_to_queue_list
    before_ms = now_ms
    jid = Sidekiq::Client.push('class' => PlainJob, 'args' => [1, 'two'], 'queue' => @queue)
    after_ms = now_ms

    assert_match JID, jid
    payload = only_queued_job

    assert_equal PLAIN_KEYS, payload.keys.sort, 'a plain push writes exactly the canonical fields'
    assert_equal jid, payload['jid']
    assert_equal 'ClientPushParityTest::PlainJob', payload['class']
    assert_equal @queue, payload['queue']
    assert_equal [1, 'two'], payload['args']
    assert_equal true, payload['retry'], 'retry defaults to true' # rubocop:disable Minitest/AssertTruthy
    assert_kind_of Integer, payload['created_at'], 'created_at is Integer epoch ms (Sidekiq 8)'
    assert_kind_of Integer, payload['enqueued_at'], 'enqueued_at is Integer epoch ms (Sidekiq 8)'
    assert_operator payload['created_at'], :>=, before_ms
    assert_operator payload['enqueued_at'], :<=, after_ms
    assert_operator payload['enqueued_at'], :>=, payload['created_at']
  end

  def test_jids_are_unique_lowercase_hex_24
    jids = Array.new(50) { Sidekiq::Client.push('class' => PlainJob, 'args' => [], 'queue' => @queue) }

    assert(jids.all? { |j| JID.match?(j) })
    assert_equal 50, jids.uniq.size
  end

  def test_class_given_as_string_is_kept_and_uses_default_job_options
    Sidekiq::Client.push('class' => 'Some::Remote::Job', 'args' => [], 'queue' => @queue)
    payload = only_queued_job

    assert_equal 'Some::Remote::Job', payload['class']
    assert_equal true, payload['retry'] # rubocop:disable Minitest/AssertTruthy
  end

  def test_default_queue_is_default
    Sidekiq::Client.push('class' => PlainJob, 'args' => [])

    assert_equal 1, redis('LLEN', 'queue:default')
    assert_equal 1, redis('SISMEMBER', 'queues', 'default')
  end

  def test_sidekiq_options_are_merged_and_item_keys_win
    OptionedJob.perform_async(1)
    payload = Wurk.load_json(redis('LINDEX', 'queue:optioned-q', 0))

    assert_equal 'optioned-q', payload['queue']
    assert_equal 5, payload['retry']
    assert_equal 3, payload['backtrace']

    Sidekiq::Client.push('class' => OptionedJob, 'args' => [], 'queue' => @queue, 'retry' => false)
    override = only_queued_job

    assert_equal @queue, override['queue']
    refute override['retry'], 'an explicit item key overrides sidekiq_options'
  end

  def test_args_round_trip_through_json
    args = [1, 2.5, 'str', nil, true, false, [1, [2]], { 'k' => { 'n' => [1] } }]
    Sidekiq::Client.push('class' => PlainJob, 'args' => args, 'queue' => @queue)

    assert_equal args, only_queued_job['args']
  end

  def test_symbol_queue_and_class_are_stringified
    Sidekiq::Client.push('class' => PlainJob, 'args' => [], 'queue' => @queue.to_sym)

    payload = only_queued_job

    assert_equal @queue, payload['queue']
    assert_equal 1, redis('SISMEMBER', 'queues', @queue)
  end

  def test_supplied_created_at_is_preserved_and_enqueued_at_is_stamped
    Sidekiq::Client.push('class' => PlainJob, 'args' => [], 'queue' => @queue,
                         'created_at' => 1_600_000_000_000, 'enqueued_at' => 1)
    payload = only_queued_job

    assert_equal 1_600_000_000_000, payload['created_at'], 'created_at ||= keeps a re-pushed job its birth time'
    assert_operator payload['enqueued_at'], :>, 1_600_000_000_000, 'enqueued_at is re-stamped on every immediate push'
  end

  def test_supplied_jid_is_kept
    jid = 'a' * 24

    assert_equal jid, Sidekiq::Client.push('class' => PlainJob, 'args' => [], 'queue' => @queue, 'jid' => jid)
    assert_equal jid, only_queued_job['jid']
  end

  def test_retry_for_is_coerced_to_integer
    Sidekiq::Client.push('class' => PlainJob, 'args' => [], 'queue' => @queue, 'retry_for' => 3600.7)

    assert_equal 3600, only_queued_job['retry_for']
  end

  def test_pool_is_transient_and_never_persisted
    PlainJob.set(queue: @queue, pool: Wurk.configuration.redis_pool).perform_async(1)

    refute only_queued_job.key?('pool')
  end

  def test_immediate_push_touches_only_queues_set_and_queue_list
    Sidekiq::Client.push('class' => PlainJob, 'args' => [], 'queue' => @queue)

    assert_equal ['queues', "queue:#{@queue}"].sort, new_keys
    assert_equal 'list', redis('TYPE', "queue:#{@queue}")
    assert_equal 'set', redis('TYPE', 'queues')
  end

  def test_push_is_lpush_so_fetch_side_pops_oldest_first
    3.times { |i| Sidekiq::Client.push('class' => PlainJob, 'args' => [i], 'queue' => @queue) }

    assert_equal [0], Wurk.load_json(redis('LINDEX', "queue:#{@queue}", -1))['args'], 'oldest job sits at the tail'
    assert_equal [2], Wurk.load_json(redis('LINDEX', "queue:#{@queue}", 0))['args'], 'newest job sits at the head'
  end

  # --- push: validation (§9 validate, §31 gotchas 1-2) ------------------------

  def test_validation_errors_raise_argument_error
    bad_items = {
      'not a hash' => 'nope',
      'missing class' => { 'args' => [] },
      'missing args' => { 'class' => PlainJob },
      'args not an Array' => { 'class' => PlainJob, 'args' => 1 },
      'class not Class|String' => { 'class' => 42, 'args' => [] },
      'non-numeric at' => { 'class' => PlainJob, 'args' => [], 'at' => '1700000000' },
      'tags not an Array' => { 'class' => PlainJob, 'args' => [], 'tags' => 'x' },
      'absolute retry_for' => { 'class' => PlainJob, 'args' => [], 'retry_for' => 1_000_000_001 },
      'empty queue' => { 'class' => PlainJob, 'args' => [], 'queue' => '' },
      'class without sidekiq options' => { 'class' => NotAJob, 'args' => [] },
      'symbol keys' => { class: PlainJob, args: [] }
    }

    bad_items.each do |label, item|
      assert_raises(ArgumentError, "#{label} must raise") { Sidekiq::Client.push(item) }
    end
    assert_equal [], new_keys, 'a rejected push writes nothing'
  end

  def test_client_push_rejects_symbol_keys
    assert_raises(ArgumentError) { PlainJob.client_push(args: [], queue: @queue) }
  end

  def test_non_json_native_args_raise_under_default_strict_mode
    [[:sym], [{ sym: 1 }], [Time.now], [Object.new], [{ 1 => 'int key' }]].each do |args|
      assert_raises(ArgumentError, "#{args.inspect} is not JSON-native") do
        Sidekiq::Client.push('class' => PlainJob, 'args' => args, 'queue' => @queue)
      end
    end
    assert_equal 0, redis('LLEN', "queue:#{@queue}")
  end

  def test_middleware_halt_returns_nil_and_writes_nothing
    client = Sidekiq::Client.new(chain: halting_chain)

    assert_nil client.push('class' => PlainJob, 'args' => [1], 'queue' => @queue)
    assert_equal 0, redis('LLEN', "queue:#{@queue}")
  end

  # --- scheduled push (§1.2, §7.1, §31 gotcha 3) ------------------------------

  def test_at_routes_to_schedule_zset_with_float_seconds_score
    at = Time.now.to_f + 600.25
    jid = Sidekiq::Client.push('class' => PlainJob, 'args' => [1], 'queue' => @queue, 'at' => at)

    assert_equal ['schedule'], new_keys, 'a scheduled push touches only the schedule ZSET'
    member, score = redis('ZRANGE', 'schedule', 0, -1, 'WITHSCORES').first
    payload = Wurk.load_json(member)

    assert_in_delta at, score.to_f, 0.001
    assert_equal jid, payload['jid']
    refute payload.key?('at'), 'at lives in the score, never in the member'
    refute payload.key?('enqueued_at'), 'a scheduled job has not been enqueued yet'
    assert_kind_of Integer, payload['created_at']
    assert_equal @queue, payload['queue']
    assert_equal 0, redis('SISMEMBER', 'queues', @queue), 'the queue is registered only when the job is enqueued'
  end

  def test_scheduled_push_strips_a_supplied_enqueued_at
    Sidekiq::Client.push('class' => PlainJob, 'args' => [], 'queue' => @queue,
                         'at' => Time.now.to_f + 60, 'enqueued_at' => now_ms)

    refute Wurk.load_json(redis('ZRANGE', 'schedule', 0, -1).first).key?('enqueued_at')
  end

  def test_perform_in_relative_absolute_and_past
    now = Time.now.to_f
    rel = PlainJob.set(queue: @queue).perform_in(120, 'rel')
    abs = PlainJob.set(queue: @queue).perform_at(now + 7200, 'abs')
    past = PlainJob.set(queue: @queue).perform_in(-5, 'past')

    assert_in_delta now + 120, score_of(rel), 2.0, 'interval < 1e9 is seconds-from-now'
    assert_in_delta now + 7200, score_of(abs), 0.01, 'interval >= 1e9 is an absolute epoch'
    assert_nil score_of(past), 'a past time enqueues immediately'
    assert_equal past, only_queued_job['jid']
    refute only_queued_job.key?('at')
  end

  def test_client_enqueue_helpers
    Sidekiq::Client.enqueue_to(@queue, PlainJob, 'to')
    Sidekiq::Client.enqueue_to_in(@queue, 300, PlainJob, 'to_in')
    Sidekiq::Client.enqueue_to_in(@queue, -1, PlainJob, 'to_in_past')

    queued = redis('LRANGE', "queue:#{@queue}", 0, -1).map { |j| Wurk.load_json(j)['args'] }

    assert_equal [['to_in_past'], ['to']], queued
    assert_equal([['to_in']], redis('ZRANGE', 'schedule', 0, -1).map { |j| Wurk.load_json(j)['args'] })
  end

  # --- push_bulk (§7.2) --------------------------------------------------------

  def test_push_bulk_gives_each_job_its_own_jid_and_preserves_fifo
    jids = Sidekiq::Client.push_bulk('class' => PlainJob, 'args' => [[1], [2], [3]], 'queue' => @queue)

    assert_equal 3, jids.size
    assert(jids.all? { |j| JID.match?(j) })
    assert_equal 3, jids.uniq.size

    tail_first = redis('LRANGE', "queue:#{@queue}", 0, -1).reverse.map { |j| Wurk.load_json(j) }

    assert_equal [[1], [2], [3]], tail_first.map { |p| p['args'] }, 'fetch order matches args order'
    assert_equal jids, tail_first.map { |p| p['jid'] }, 'returned jids line up with args'
    assert_equal 1, tail_first.map { |p| p['enqueued_at'] }.uniq.size, 'one enqueued_at per pushed batch'
    tail_first.each do |p|
      assert_equal PLAIN_KEYS, p.keys.sort
      assert_equal @queue, p['queue']
    end
  end

  def test_push_bulk_slices_by_batch_size
    jids = Sidekiq::Client.push_bulk('class' => PlainJob, 'args' => Array.new(7) { |i| [i] },
                                     'queue' => @queue, 'batch_size' => 3)

    assert_equal 7, jids.compact.size
    assert_equal 7, redis('LLEN', "queue:#{@queue}")
    tail_first = redis('LRANGE', "queue:#{@queue}", 0, -1).reverse.map { |j| Wurk.load_json(j) }

    assert_equal(jids, tail_first.map { |p| p['jid'] })
  end

  def test_push_bulk_empty_args_returns_empty_and_writes_nothing
    assert_equal [], Sidekiq::Client.push_bulk('class' => PlainJob, 'args' => [], 'queue' => @queue)
    assert_equal [], new_keys
  end

  def test_push_bulk_single_at_schedules_every_job_at_that_time
    at = Time.now.to_f + 900
    jids = Sidekiq::Client.push_bulk('class' => PlainJob, 'args' => [[1], [2]], 'queue' => @queue, 'at' => at)

    entries = redis('ZRANGE', 'schedule', 0, -1, 'WITHSCORES')

    assert_equal jids.sort, entries.map { |m, _| Wurk.load_json(m)['jid'] }.sort
    entries.each do |member, score|
      assert_in_delta at, score.to_f, 0.001
      refute Wurk.load_json(member).key?('at')
    end
    assert_equal 0, redis('EXISTS', "queue:#{@queue}")
  end

  def test_push_bulk_at_array_schedules_each_job_at_its_own_time
    base = Time.now.to_f
    ats = [base + 100, base + 200, base + 300]
    jids = Sidekiq::Client.push_bulk('class' => PlainJob, 'args' => [[1], [2], [3]], 'queue' => @queue, 'at' => ats)

    jids.each_with_index do |jid, i|
      assert_in_delta ats[i], score_of(jid), 0.001
    end
  end

  def test_push_bulk_spread_interval_spreads_within_window
    now = Time.now.to_f
    jids = Sidekiq::Client.push_bulk('class' => PlainJob, 'args' => Array.new(20) { |i| [i] },
                                     'queue' => @queue, 'spread_interval' => 60)

    scores = jids.map { |j| score_of(j) }

    assert(scores.all? { |s| s.between?(now - 1, now + 61) }, "scores outside the window: #{scores.inspect}")
    assert_operator scores.uniq.size, :>, 1, 'jobs are spread, not stacked'
  end

  def test_push_bulk_spread_interval_floors_at_five_seconds
    now = Time.now.to_f
    jids = Sidekiq::Client.push_bulk('class' => PlainJob, 'args' => Array.new(30) { |i| [i] },
                                     'queue' => @queue, 'spread_interval' => 0.001)

    scores = jids.map { |j| score_of(j) }.compact

    assert_equal 30, scores.size, 'a tiny spread still schedules every job'
    assert(scores.all? { |s| s.between?(now - 1, now + 6) })
    assert_operator scores.max - scores.min, :>, 0.01, 'the window is max(spread_interval, 5), not 1ms'
  end

  def test_push_bulk_validation_errors
    base = { 'class' => PlainJob, 'queue' => @queue }
    bad = {
      'at Array size mismatch' => base.merge('args' => [[1], [2]], 'at' => [Time.now.to_f]),
      'empty at Array' => base.merge('args' => [[1]], 'at' => []),
      'non-numeric at' => base.merge('args' => [[1]], 'at' => 'soon'),
      'non-numeric at entry' => base.merge('args' => [[1], [2]], 'at' => [Time.now.to_f, 'x']),
      'at with spread_interval' => base.merge('args' => [[1]], 'at' => Time.now.to_f, 'spread_interval' => 10),
      'zero spread_interval' => base.merge('args' => [[1]], 'spread_interval' => 0),
      'non-numeric spread_interval' => base.merge('args' => [[1]], 'spread_interval' => '10'),
      'jid with many jobs' => base.merge('args' => [[1], [2]], 'jid' => 'b' * 24),
      'args not Array of Arrays' => base.merge('args' => [1, 2])
    }

    bad.each do |label, items|
      assert_raises(ArgumentError, "#{label} must raise") { Sidekiq::Client.push_bulk(items) }
    end
    assert_equal [], new_keys
  end

  def test_push_bulk_middleware_halt_yields_nil_entries
    client = Sidekiq::Client.new(chain: halting_chain)
    jids = client.push_bulk('class' => PlainJob, 'args' => [[1], [2], [3], [4]], 'queue' => @queue)

    assert_nil jids[0]
    assert_match JID, jids[1]
    assert_nil jids[2]
    assert_match JID, jids[3]
    assert_equal([[2], [4]], redis('LRANGE', "queue:#{@queue}", 0, -1).reverse.map { |j| Wurk.load_json(j)['args'] })
  end

  def test_perform_bulk_dsl
    jids = PlainJob.set(queue: @queue).perform_bulk([[1], [2]])

    assert_equal 2, jids.compact.size
    assert_equal 2, redis('LLEN', "queue:#{@queue}")
  end

  # --- ActiveJob wrapper (§28) -------------------------------------------------

  def test_active_job_payload_uses_the_sidekiq_wrapper_class
    job_class = aj_class
    with_aj_adapter(job_class) { job_class.perform_later(1, 'x') }

    payload = only_queued_job

    assert_equal 'Sidekiq::ActiveJob::Wrapper', payload['class']
    assert_equal job_class.name, payload['wrapped']
    assert_equal @queue, payload['queue']
    assert_equal 1, payload['args'].size
    assert_equal job_class.name, payload['args'][0]['job_class']
    assert_equal [1, 'x'], payload['args'][0]['arguments']
    assert_match JID, payload['jid']
    assert_kind_of Integer, payload['created_at']
    assert_kind_of Integer, payload['enqueued_at']
  end

  def test_active_job_scheduled_payload_lands_in_schedule
    job_class = aj_class
    at = Time.now + 3600
    with_aj_adapter(job_class) { job_class.set(wait_until: at).perform_later(2) }

    member, score = redis('ZRANGE', 'schedule', 0, -1, 'WITHSCORES').first
    payload = Wurk.load_json(member)

    assert_in_delta at.to_f, score.to_f, 0.01
    assert_equal 'Sidekiq::ActiveJob::Wrapper', payload['class']
    assert_equal job_class.name, payload['wrapped']
    refute payload.key?('enqueued_at')
  end

  def test_active_job_perform_all_later_bulk_pushes_wrapped_jobs
    job_class = aj_class
    with_aj_adapter(job_class) { ActiveJob.perform_all_later([job_class.new(1), job_class.new(2)]) }

    payloads = redis('LRANGE', "queue:#{@queue}", 0, -1).reverse.map { |j| Wurk.load_json(j) }

    assert_equal 2, payloads.size
    assert(payloads.all? { |p| p['class'] == 'Sidekiq::ActiveJob::Wrapper' && p['wrapped'] == job_class.name })
    assert_equal([[1], [2]], payloads.map { |p| p['args'][0]['arguments'] })
  end

  private

  def redis(*cmd)
    Wurk.redis { |c| c.call(*cmd) }
  end

  def now_ms
    ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
  end

  def new_keys
    (redis('KEYS', '*') - @before_keys).sort
  end

  def only_queued_job
    entries = redis('LRANGE', "queue:#{@queue}", 0, -1)

    assert_equal 1, entries.size, "expected one job in queue:#{@queue}, got #{entries.size}"
    Wurk.load_json(entries.first)
  end

  def score_of(jid)
    redis('ZRANGE', 'schedule', 0, -1, 'WITHSCORES').each do |member, score|
      return score.to_f if Wurk.load_json(member)['jid'] == jid
    end
    nil
  end

  def halting_chain
    Sidekiq::Middleware::Chain.new.tap { |chain| chain.add HaltOddArgs }
  end

  def aj_class
    queue = @queue
    klass = Class.new(ActiveJob::Base) do
      queue_as queue
      def perform(*); end
    end
    self.class.const_set("AjJob#{object_id}", klass)
  end

  def with_aj_adapter(job_class)
    job_class.queue_adapter = :sidekiq
    yield
  ensure
    self.class.send(:remove_const, job_class.name.split('::').last) if job_class
  end
end
