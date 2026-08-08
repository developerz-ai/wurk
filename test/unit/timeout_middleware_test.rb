# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Pins Wurk::Middleware::Timeout, the per-attempt wall-clock bound behind
# `sidekiq_options timeout:`. Three properties carry it: a class that declares
# no bound arms nothing and starts no timer, a class that declares one has its
# attempt cut by an error it can still rescue, and the cut is booked as the
# failure it is — which is a fact about where the middleware sits in the chain,
# not about the middleware itself, so the last one runs through the real chain.
class TimeoutMiddlewareTest < Wurk::Test::UnitCase
  parallelize_me!

  # Registration order in lib/wurk.rb. Chain walks entries outside-in on the way
  # in and unwinds inside-out on the way out, so the LOWER index is the OUTER
  # middleware: everything that acks or reschedules a job the bound may have cut
  # belongs outside it, everything that books the attempt belongs inside.
  OUTER_OF_TIMEOUT = [
    Wurk::Batch::ServerMiddleware,
    Wurk::Middleware::Expiry,
    Wurk::Limiter::ServerMiddleware
  ].freeze
  INNER_OF_TIMEOUT = [
    Wurk::Metrics::Statsd,
    Wurk::Metrics::History,
    Wurk::Middleware::Status
  ].freeze

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @capsule = Wurk::Capsule.new("timeout-#{Process.pid}-#{object_id}", @config)
    @watchdogs = []
    @booked = []
  end

  def teardown
    @watchdogs.each(&:terminate)
    drop_bucket_fields
  ensure
    super
  end

  # ---- nothing declared, nothing paid --------------------------------------

  def test_a_job_without_a_bound_yields_and_arms_nothing
    watchdog = attach_watchdog

    assert_equal :ok, invoke({ 'class' => 'PlainJob' }) { :ok }
    assert_equal 0, watchdog.size
    refute_predicate watchdog, :running?, 'a class with no timeout: must not start the scanner'
  end

  # Every shape JSON can leave in the field that isn't a usable number of
  # seconds. Declaration-time validation rejects these where they are written;
  # a payload from stock Sidekiq, a raw LPUSH, or a release older than the
  # option never met that check, and must still run.
  def test_an_unusable_bound_leaves_the_job_unbounded
    watchdog = attach_watchdog

    ['30', 0, -1, Float::INFINITY, Float::NAN, nil, true].each do |value|
      assert_equal :ok, invoke({ 'class' => 'PlainJob', 'timeout' => value }) { :ok }, "#{value.inspect} armed a bound"
    end

    refute_predicate watchdog, :running?
  end

  # A Configuration owns no watchdog — only a Capsule does — and a chain bound
  # to one is what `Wurk::Testing.inline!` and a hand-driven chain invoke.
  def test_a_config_that_owns_no_watchdog_runs_the_job_unbounded
    result = build(@config).call(nil, bounded_job(0.01), 'default') do
      sleep 0.05
      :ok
    end

    assert_equal :ok, result
  end

  # Capsule#prepare! is what builds the watchdog, so a capsule the launcher
  # never got that far with has none. The bound is a safety net; a missing timer
  # is not a reason to fail the job.
  def test_an_unprepared_capsule_runs_the_job_unbounded
    assert_nil @capsule.watchdog

    result = build(@capsule).call(nil, bounded_job(0.01), 'default') do
      sleep 0.05
      :ok
    end

    assert_equal :ok, result
  end

  # ---- bound met -----------------------------------------------------------

  def test_a_job_inside_its_bound_returns_its_value_and_retracts
    watchdog = attach_watchdog

    assert_equal :ok, invoke(bounded_job(5)) { :ok }
    assert_equal 0, watchdog.size
  end

  # Nothing may outlive the attempt: a pending raise here would land on the ACK
  # or on the next job, the stdlib `Timeout` failure mode Watchdog exists to
  # avoid, now proven through its caller.
  def test_a_completed_attempt_leaves_no_pending_interrupt
    attach_watchdog

    invoke(bounded_job(5)) { sleep 0.05 }

    refute_predicate Thread, :pending_interrupt?
  end

  # ---- bound exceeded ------------------------------------------------------

  def test_a_job_over_its_bound_is_cut_with_a_named_error
    watchdog = attach_watchdog

    err = assert_raises(Wurk::Job::TimedOut) { invoke(bounded_job(0.02, 'SlowJob')) { sleep 5 } }

    assert_equal 'SlowJob timed out after 0.02s', err.message
    assert_equal 0, watchdog.size
  end

  # Soft, by contract. The job sees an ordinary error and gets to clean up
  # behind itself — `Thread#kill` would strand whatever `perform` was holding.
  def test_the_cut_is_an_error_the_job_can_rescue
    attach_watchdog
    cleaned = false

    result = invoke(bounded_job(0.02)) do
      sleep 5
    rescue Wurk::Job::TimedOut
      cleaned = true
      :cleaned_up
    end

    assert_equal :cleaned_up, result
    assert cleaned
  end

  # Per attempt, not per job: the retry of a job that timed out is handed the
  # whole budget again rather than inheriting an exhausted one.
  def test_each_attempt_gets_its_own_bound
    attach_watchdog
    job = bounded_job(0.05)

    assert_raises(Wurk::Job::TimedOut) { invoke(job) { sleep 5 } }
    assert_equal :ok, invoke(job) { :ok }
  end

  # ---- chain position ------------------------------------------------------

  def test_registered_between_the_reschedulers_and_the_bookkeepers
    klasses = Wurk.configuration.server_middleware.map(&:klass)
    index = klasses.index(Wurk::Middleware::Timeout)

    refute_nil index, 'Middleware::Timeout must be auto-registered on the server chain'
    OUTER_OF_TIMEOUT.each do |klass|
      assert_operator klasses.index(klass), :<, index, "#{klass} must be registered OUTER of Timeout"
    end
    INNER_OF_TIMEOUT.each do |klass|
      assert_operator klasses.index(klass), :>, index, "#{klass} must be registered INNER of Timeout"
    end
  end

  # Isolation proves the middleware arms a bound; only the real chain proves the
  # position pays for itself. A `TimedOut` raised from the job body has to unwind
  # through Metrics::History and be booked `f` — register Timeout inside History
  # instead and the cut never reaches it, so a job that hung is a job that, as
  # far as every metric in the dashboard is concerned, never happened.
  def test_a_timeout_through_the_real_chain_books_a_failure
    klass = book("TimeoutJob-#{SecureRandom.hex(8)}")
    job = { 'class' => klass, 'args' => [], 'jid' => SecureRandom.hex(12), 'queue' => 'default' }
    before = ::Time.now.utc

    assert_raises(Wurk::Job::TimedOut) do
      real_chain.invoke(nil, job, 'default') { raise Wurk::Job::TimedOut, 'cut' }
    end
    Wurk::Metrics::History.flush

    assert_includes recorded_fields(klass, before), 'f'
  end

  # ---- zero cost, at process scope ------------------------------------------

  # The other tests in this file pin "zero cost" through the Watchdog's own
  # bookkeeping (#size, #running?); this one pins the claim the plan doc asks
  # for literally — the OS thread count of the process a class with no bound
  # runs in must not move, not just the Watchdog's private view of itself.
  def test_no_bound_configured_leaves_the_process_thread_count_unchanged
    attach_watchdog
    before = Thread.list.size

    100.times { assert_equal :ok, invoke({ 'class' => 'PlainJob' }) { :ok } }

    assert_equal before, Thread.list.size
  end

  # ---- leak check ------------------------------------------------------------

  # 1000 attempts, every one cut, through the real registered chain (Batch,
  # Expiry, Limiter, Timeout, Statsd, History, Status) — the same RAII
  # discipline docs/plans/2026/07/31/101-leak-logic-perf-fixes/ closed applies
  # here: an interrupt landing mid-bookkeeping must never strand a Redis
  # checkout or an OS thread. One class, so the minute-bucket field this
  # leaves behind is one HINCRBY target, not a thousand.
  def test_a_thousand_cut_attempts_leak_no_thread_or_connection
    klass = book("TimeoutLeakJob-#{SecureRandom.hex(8)}")
    job = { 'class' => klass, 'args' => [], 'jid' => SecureRandom.hex(12), 'queue' => 'default' }
    pool = Wurk.configuration.default_capsule.redis_pool
    threads_before = Thread.list.size
    available_before = pool.available

    1000.times do
      assert_raises(Wurk::Job::TimedOut) do
        real_chain.invoke(nil, job, 'default') { raise Wurk::Job::TimedOut, 'cut' }
      end
    end

    assert_equal threads_before, Thread.list.size, 'no thread may accumulate across 1000 cut attempts'
    assert_equal available_before, pool.available, 'every Redis checkout the chain took must have been returned'
  end

  private

  def build(config)
    Wurk::Middleware::Timeout.new.tap { |middleware| middleware.config = config }
  end

  def invoke(job, &)
    build(@capsule).call(nil, job, 'default', &)
  end

  def bounded_job(seconds, klass = 'BoundedJob')
    { 'class' => klass, 'timeout' => seconds }
  end

  # What Capsule#prepare! assigns in production, minus the Redis pools and the
  # fetcher it opens on the way. The fast scan keeps a blown bound in the
  # milliseconds instead of SCAN_INTERVAL.
  def attach_watchdog(interval: 0.01)
    Wurk::Watchdog.new(@capsule, interval: interval).tap do |watchdog|
      @watchdogs << watchdog
      @capsule.instance_variable_set(:@watchdog, watchdog)
    end
  end

  def real_chain = Wurk.configuration.default_capsule.server_middleware

  def book(klass)
    @booked << klass
    klass
  end

  # The middleware records at its own Time.now, which may cross a minute
  # boundary, so both candidate buckets are merged.
  def recorded_fields(klass, started_at)
    minute_keys(started_at).flat_map do |key|
      raw = Wurk.redis { |conn| conn.call('HGETALL', key) }
      fields = raw.is_a?(::Hash) ? raw.keys : raw.each_slice(2).map(&:first)
      fields.select { |field| field.start_with?("#{klass}|") }.map { |field| field.split('|', 2).last }
    end
  end

  def minute_keys(started_at)
    [started_at, ::Time.now.utc].map { |t| Wurk::Metrics::History.minute_key(t) }.uniq
  end

  # Per-class fields live in shared minute buckets no FLUSHDB-per-test reaches
  # before a parallel sibling reads them, so drop exactly the ones booked here.
  def drop_bucket_fields
    return if @booked.empty?

    Wurk.redis do |conn|
      minute_keys(::Time.now.utc - 60).each do |key|
        mine = conn.call('HKEYS', key).select { |field| @booked.any? { |klass| field.start_with?("#{klass}|") } }
        conn.call('HDEL', key, *mine) unless mine.empty?
      end
    end
  end
end
