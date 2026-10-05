# frozen_string_literal: true

require_relative '../test_helper'

class PeriodicParityOptionsJob
  include Sidekiq::Job

  sidekiq_options queue: 'periodic-parity-low', retry: 4, expires_in: 3600

  def perform(*); end
end

class PeriodicParityPlainJob
  include Sidekiq::Job

  def perform(*); end
end

# Parity oracle for Sidekiq Enterprise periodic jobs, written from the spec,
# not from Wurk's cron.rb:
#
#   * §2.2 — a tick is `klass.perform_async(*args)` with the loop's `retry` /
#     `queue` laid over the worker's own options; `args` passes verbatim.
#   * §2.4 — pause / unpause is the `paused` field of the `loops:{lid}` HASH.
#   * §2.6 — missed ticks are not backfilled (leader gap, restart).
#
# Driving a tick needs the leader poller; spec §2 defines no public tick API,
# so the oracle claims leadership on Wurk's poller and observes only the
# documented surface: queue contents, `loops:{lid}`, LoopSet.
#
# Not parallelize_me!: a tick fires every loop in the shared `periodic` set,
# and the no-backfill case stubs the process clock.
class PeriodicParityTest < Wurk::Test::UnitCase
  VOLATILE = %w[jid created_at enqueued_at expiry].freeze

  def setup
    super
    @lids = []
    @queues = ['periodic-parity-low']
    @poller = Wurk::Cron::Poller.new(Wurk.configuration)
    @poller.define_singleton_method(:leader?) { true }
    @poller.define_singleton_method(:logger) { ::Logger.new(IO::NULL) }
  end

  def teardown
    @lids.each do |lid|
      Wurk.redis do |c|
        c.call('SREM', 'periodic', lid)
        c.call('DEL', "loops:#{lid}", "loop-history:#{lid}")
      end
    end
    Wurk.redis do |c|
      @queues.each do |q|
        c.call('DEL', "queue:#{q}")
        c.call('SREM', 'queues', q)
      end
    end
  ensure
    super
  end

  # §2.2: the tick's payload is the one perform_async builds for the same args.
  def test_a_tick_enqueues_what_perform_async_would
    register('* * * * *', 'PeriodicParityOptionsJob', args: ['nightly', 2])

    @poller.tick
    ticked = pop('periodic-parity-low')
    PeriodicParityOptionsJob.perform_async('nightly', 2)
    direct = pop('periodic-parity-low')

    refute_nil ticked, 'the tick lands in the queue the worker declares'
    assert_equal direct.except(*VOLATILE), ticked.except(*VOLATILE)
    assert ticked.key?('expiry'), 'expires_in applies to the periodic push too'
  end

  # §2.2 table: `retry` and `queue` are recognized loop options and override.
  def test_loop_retry_and_queue_override_the_worker
    queue = queue_named('override')
    register('* * * * *', 'PeriodicParityOptionsJob', retry: 2, queue: queue)

    @poller.tick
    job = pop(queue)

    refute_nil job
    assert_equal 2, job['retry']
  end

  # §2.2: `opts[:args]` passed verbatim into perform_async(*args).
  def test_args_pass_verbatim
    queue = queue_named('args')
    register('* * * * *', 'PeriodicParityPlainJob', queue: queue, args: [{ 'k' => [1, 'two'] }, nil])

    @poller.tick

    assert_equal [{ 'k' => [1, 'two'] }, nil], pop(queue)['args']
  end

  # §2.4: pause writes paused:1 to the loop HASH; unpause clears it and the
  # loop runs again.
  def test_pause_and_unpause_are_the_loop_hash_field
    queue = queue_named('pause')
    lid = register('* * * * *', 'PeriodicParityPlainJob', queue: queue)

    Wurk.redis { |c| c.call('HSET', "loops:#{lid}", 'paused', '1') }
    @poller.tick

    assert_nil pop(queue), 'a paused loop does not enqueue'
    assert_predicate Sidekiq::Periodic::LoopSet.new.fetch(lid), :paused?

    Wurk.redis { |c| c.call('HSET', "loops:#{lid}", 'paused', '0') }
    @poller.tick

    refute_predicate Sidekiq::Periodic::LoopSet.new.fetch(lid), :paused?
    refute_nil pop(queue), 'an unpaused loop enqueues'
  end

  # §2.6: no backfill. An hourly loop fires, the leader goes away for an hour
  # and a half, a leader ticks again: the occurrence that fell inside the gap
  # is not enqueued, and the next one is still in the future.
  def test_missed_ticks_are_not_backfilled_after_a_gap
    queue = queue_named('gap')
    start = ::Time.now
    register("#{start.utc.min} * * * *", 'PeriodicParityPlainJob', queue: queue)

    @poller.tick

    assert_equal 1, llen(queue), 'the first tick fires the current slot'

    at(start + 5400) { @poller.tick }

    assert_equal 1, llen(queue), 'the slot missed during the gap is not backfilled'
  end

  private

  # Minitest 6 dropped minitest/mock; a singleton override is the stub.
  def at(time)
    original = ::Time.method(:now)
    ::Time.singleton_class.send(:define_method, :now) { time }
    yield
  ensure
    ::Time.singleton_class.send(:define_method, :now, original)
  end

  def register(cron, klass, **)
    lid = Sidekiq::Periodic::Manager.new.register(cron, klass, **).lid
    @lids << lid
    lid
  end

  def queue_named(tag)
    "periodic-parity-#{tag}-#{Process.pid}-#{object_id}".tap { |q| @queues << q }
  end

  def pop(queue)
    raw = Wurk.redis { |c| c.call('RPOP', "queue:#{queue}") }
    raw && JSON.parse(raw)
  end

  def llen(queue)
    Wurk.redis { |c| c.call('LLEN', "queue:#{queue}") }
  end
end
