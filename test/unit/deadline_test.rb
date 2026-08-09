# frozen_string_literal: true

require_relative '../test_helper'

# `sidekiq_options deadline: <seconds>` end to end: rejected where it is
# written, resolved to an absolute cutoff once at push, and enforced twice —
# before `perform` by Wurk::Middleware::Expiry, and during it by the watchdog
# Wurk::Middleware::Timeout arms with whatever is left.
#
# The property that separates it from `timeout:` is that it is absolute. A
# `timeout` is renewed by every attempt; a deadline is stamped once and every
# later attempt measures against that same instant, so retries and IterableJob
# resumes cannot outlive it.
class DeadlineTest < Wurk::Test::UnitCase
  parallelize_me!

  # Enough of ActiveSupport::Duration to pin the case that matters: it is not a
  # Numeric subclass, it answers `is_a?(Numeric)` by delegating to its value,
  # and `deadline: 5.minutes` is how the option will actually be written.
  class DurationLike
    def initialize(value) = @value = value
    def is_a?(klass) = klass == DurationLike || @value.is_a?(klass)
    def to_f = @value.to_f
  end

  # Every shape JSON (or a typo) can leave in a bound field that is not a
  # positive, finite number of seconds.
  UNUSABLE = ['300', 0, -1, Float::INFINITY, Float::NAN, true, :soon].freeze

  # The subset of UNUSABLE that is not a readable instant either. `'300'`, `0`
  # and `-1` are unusable as durations and perfectly readable as cutoffs — all
  # three are long past, and Middleware::Expiry drops on them, which is what
  # Sidekiq Pro's bare `Time.now.to_f > job['expiry']` does too.
  UNREADABLE = ['soon', true, :soon, Float::INFINITY, Float::NAN].freeze

  CREATED_AT_MS = 1_700_000_000_000
  CREATED_AT_S = CREATED_AT_MS / 1000.0

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @capsule = Wurk::Capsule.new("deadline-#{Process.pid}-#{object_id}", @config)
    @watchdogs = []
  end

  def teardown
    @watchdogs.each(&:terminate)
  ensure
    super
  end

  # --- validation, at the door it was written --------------------------

  def test_the_worker_dsl_accepts_a_positive_number_of_seconds
    klass = Class.new { include Wurk::Worker }

    assert_equal 300, klass.sidekiq_options(deadline: 300)['deadline']
    assert_in_delta 1.5, klass.sidekiq_options(timeout: 1.5)['timeout']
  end

  def test_the_worker_dsl_accepts_an_activesupport_duration
    klass = Class.new { include Wurk::Worker }
    duration = DurationLike.new(300)

    assert_same duration, klass.sidekiq_options(deadline: duration)['deadline']
  end

  def test_the_worker_dsl_rejects_an_unusable_bound
    klass = Class.new { include Wurk::Worker }

    UNUSABLE.each do |value|
      error = assert_raises(ArgumentError, "#{value.inspect} was accepted") { klass.sidekiq_options(deadline: value) }
      assert_match(/'deadline' must be a positive number of seconds/, error.message)
    end
    refute klass.get_sidekiq_options.key?('deadline'), 'a rejected option must not be half-applied'
  end

  # Both bounds go through the same check, so neither can be tightened without
  # the other.
  def test_the_worker_dsl_rejects_an_unusable_timeout
    klass = Class.new { include Wurk::Worker }

    error = assert_raises(ArgumentError) { klass.sidekiq_options(timeout: -5) }
    assert_match(/'timeout' must be a positive number of seconds/, error.message)
  end

  # The ActiveJob options DSL is a second copy of the same surface; a bad value
  # has to fail identically there or the two drift.
  def test_the_activejob_options_dsl_rejects_an_unusable_bound
    klass = Class.new { include Wurk::Job::Options }

    assert_raises(ArgumentError) { klass.sidekiq_options(deadline: '300') }
    assert_equal 300, klass.sidekiq_options(deadline: 300)['deadline']
  end

  def test_a_string_keyed_bound_is_validated_too
    klass = Class.new { include Wurk::Worker }

    assert_raises(ArgumentError) { klass.sidekiq_options('deadline' => 0) }
  end

  # The other door: a payload handed straight to the client, never through a
  # class-level option.
  def test_an_unusable_bound_is_rejected_at_push
    error = assert_raises(ArgumentError) { normalize(job('deadline' => Float::NAN)) }

    assert_match(/'deadline' must be a positive number of seconds/, error.message)
  end

  def test_an_absent_bound_is_not_an_error
    payload = normalize(job)

    refute payload.key?('deadline')
    refute payload.key?('deadline_at')
  end

  # --- absolute carry ---------------------------------------------------

  def test_push_resolves_the_relative_option_to_an_absolute_cutoff
    payload = normalize(job('deadline' => 300, 'created_at' => CREATED_AT_MS))

    assert_in_delta CREATED_AT_S + 300, payload['deadline_at'], 0.001
    assert_equal 300, payload['deadline'], 'the declaration stays on the payload'
  end

  # Same rule `expires_in` follows: for a scheduled job the clock starts when
  # the job is due, or perform_in(2h) + deadline: 5.minutes would be born past
  # its cutoff and could never run.
  def test_a_scheduled_job_measures_from_its_run_time
    at = CREATED_AT_S + 7200
    payload = normalize(job('deadline' => 300, 'created_at' => CREATED_AT_MS, 'at' => at))

    assert_in_delta at + 300, payload['deadline_at'], 0.001
    assert_operator payload['deadline_at'], :>, at, 'a scheduled job must not be born past its deadline'
  end

  def test_a_class_level_deadline_reaches_the_payload
    klass = Class.new { include Wurk::Worker }
    klass.sidekiq_options(deadline: 300, queue: 'default')
    payload = normalize({ 'class' => klass, 'args' => [], 'created_at' => CREATED_AT_MS })

    assert_in_delta CREATED_AT_S + 300, payload['deadline_at'], 0.001
  end

  # The whole point of the option. A retry re-ZADDs this hash and an
  # interrupted IterableJob re-pushes it verbatim, so the cutoff rides along
  # unchanged — and a path that re-normalizes must not restart the clock.
  def test_the_cutoff_survives_re_enqueue
    payload = normalize(job('deadline' => 300, 'created_at' => CREATED_AT_MS))
    original = payload['deadline_at']

    resumed = Wurk.load_json(Wurk.dump_json(payload))
    resumed['created_at'] = CREATED_AT_MS + 600_000
    renormalized = normalize(resumed)

    assert_in_delta original, renormalized['deadline_at'], 0.001
  end

  # A `deadline` no door validated — a class option set some other way, a
  # default_job_options entry — is left unstamped rather than raised on, which
  # is the same answer Middleware::Timeout gives a bound it cannot arm.
  def test_an_unusable_class_default_is_left_unstamped
    stamper = Class.new { include Wurk::JobUtil }.new
    item = { 'class' => 'X', 'args' => [], 'created_at' => CREATED_AT_MS, 'deadline' => '300' }

    stamper.send(:stamp_deadline, item)

    refute item.key?('deadline_at')
  end

  # --- before perform ---------------------------------------------------

  def test_a_job_past_its_cutoff_never_starts
    with_expired_counter do
      refute yielded_through_expiry?('deadline_at' => ::Time.now.to_f - 1)
      assert_equal 1, Wurk::Processor::EXPIRED.reset
    end
  end

  def test_a_job_inside_its_cutoff_runs
    with_expired_counter do
      assert yielded_through_expiry?('deadline_at' => ::Time.now.to_f + 60)
      assert_equal 0, Wurk::Processor::EXPIRED.reset
    end
  end

  # Two windows, and the one that closes first is the one that counts —
  # whichever option opened it.
  def test_the_earlier_of_the_two_windows_wins
    now = ::Time.now.to_f

    refute yielded_through_expiry?('expiry' => now - 1, 'deadline_at' => now + 60)
    refute yielded_through_expiry?('expiry' => now + 60, 'deadline_at' => now - 1)
    assert yielded_through_expiry?('expiry' => now + 60, 'deadline_at' => now + 60)
  end

  # The mirror of test_an_unusable_cutoff_leaves_the_job_unbounded, on the same
  # field. Expiry is the outer frame, so a cutoff it reads differently is the
  # one that lands: a `deadline_at` it cannot read has to run the job, not
  # discard it, or Timeout's policy never gets a say.
  def test_a_cutoff_neither_middleware_can_read_leaves_the_job_alone
    live = ::Time.now.to_f + 60
    with_expired_counter do
      UNREADABLE.each do |value|
        assert yielded_through_expiry?('deadline_at' => value), "deadline_at #{value.inspect} dropped the job"
        assert yielded_through_expiry?('expiry' => value), "expiry #{value.inspect} dropped the job"
        # And it is dropped, not carried into the comparison: NaN and Infinity
        # both poison a `min` against the window that *was* readable.
        assert yielded_through_expiry?('expiry' => live, 'deadline_at' => value),
               "deadline_at #{value.inspect} broke the readable window beside it"
      end

      assert_equal 0, Wurk::Processor::EXPIRED.reset
    end
  end

  # The tolerance that guard must not cost: a cutoff that round-tripped as a
  # String is a value, not a typo, and still closes its window.
  def test_a_cutoff_that_round_tripped_as_a_string_still_expires
    with_expired_counter do
      refute yielded_through_expiry?('deadline_at' => (::Time.now.to_f - 1).to_s)
      assert_equal 1, Wurk::Processor::EXPIRED.reset
    end
  end

  # Only a job carrying a cutoff can be cut by one. Without a cutoff the same
  # exception is the job's own, and it unwinds to JobRetry rather than being
  # swallowed into a clean ack.
  def test_a_deadline_error_from_a_job_that_declared_none_is_not_swallowed
    with_expired_counter do
      assert_raises(Wurk::Job::DeadlineExceeded) do
        expiry.call(nil, job, 'q') { raise Wurk::Job::DeadlineExceeded }
      end

      assert_equal 0, Wurk::Processor::EXPIRED.reset
    end
  end

  def test_the_drop_emits_the_same_statsd_counter_as_expires_in
    with_statsd_recorder do |calls|
      expiry.call(nil, job('class' => 'MyJob', 'deadline_at' => ::Time.now.to_f - 1), 'q') { flunk 'must not yield' }

      assert_equal [['jobs.expired', ['class:MyJob']]], calls
    end
  end

  # --- during perform ---------------------------------------------------

  def test_a_running_job_is_cut_when_the_cutoff_passes
    attach_watchdog
    started = false

    error = assert_raises(Wurk::Job::DeadlineExceeded) do
      timeout.call(nil, running_job(0.02), 'q') do
        started = true
        sleep 5
      end
    end

    assert started, 'the job must start — the cutoff had not passed yet'
    assert_equal 'SlowJob exceeded its deadline', error.message
  end

  def test_the_cut_is_booked_expired_and_not_retried
    attach_watchdog
    with_expired_counter do
      result = expiry.call(nil, running_job(0.02), 'q') do
        timeout.call(nil, running_job(0.02), 'q') { sleep 5 }
      end

      assert_nil result, 'a swallowed cut is a clean exit: JobRetry never sees it, the processor acks'
      assert_equal 1, Wurk::Processor::EXPIRED.reset
    end
  end

  # A job may rescue the cut to clean up behind itself — soft by contract, the
  # same bargain `timeout:` makes.
  def test_the_cut_is_an_error_the_job_can_rescue
    attach_watchdog

    result = timeout.call(nil, running_job(0.02), 'q') do
      sleep 5
    rescue Wurk::Job::DeadlineExceeded
      :cleaned_up
    end

    assert_equal :cleaned_up, result
  end

  def test_both_bounds_are_armed_independently
    watchdog = attach_watchdog
    armed = nil
    job = running_job(5).merge('timeout' => 5)

    timeout.call(nil, job, 'q') { armed = watchdog.size }

    assert_equal 2, armed, 'a job declaring both must hold both bounds at once'
    assert_equal 0, watchdog.size, 'and retract both on the way out'
  end

  # The absolute bound is armed outside the per-attempt one, so a job that
  # swallows its `TimedOut` and carries on is still cut by its deadline. The
  # deadline is a whole second rather than the milliseconds the other timing
  # tests use: those race `sleep 5` and have unbounded margin, this one has a
  # real ceiling, and a loaded parallel CI run can eat a tenth of a second in
  # scheduling alone.
  def test_the_deadline_outlives_a_swallowed_timeout
    attach_watchdog
    job = running_job(1.0).merge('timeout' => 0.02)

    assert_raises(Wurk::Job::DeadlineExceeded) do
      timeout.call(nil, job, 'q') do
        sleep 5
      rescue Wurk::Job::TimedOut
        sleep 5
      end
    end
  end

  def test_a_job_without_a_cutoff_arms_nothing
    watchdog = attach_watchdog

    assert_equal :ok, timeout.call(nil, job, 'q') { :ok }
    refute_predicate watchdog, :running?
  end

  # Declaration-time validation never saw a payload from stock Sidekiq or a raw
  # LPUSH; an unusable cutoff on one of those leaves the job unbounded rather
  # than failing it.
  def test_an_unusable_cutoff_leaves_the_job_unbounded
    watchdog = attach_watchdog

    UNUSABLE.each do |value|
      assert_equal :ok, timeout.call(nil, job('deadline_at' => value), 'q') { :ok }, "#{value.inspect} armed a bound"
    end
    refute_predicate watchdog, :running?
  end

  private

  def job(extra = {})
    { 'class' => 'DeadlineJob', 'args' => [] }.merge(extra)
  end

  def running_job(seconds_left)
    job('class' => 'SlowJob', 'deadline_at' => ::Time.now.to_f + seconds_left)
  end

  def normalize(item)
    Class.new { include Wurk::JobUtil }.new.normalize_item(item)
  end

  def expiry
    Wurk::Middleware::Expiry.new.tap { |middleware| middleware.config = @config }
  end

  def timeout
    Wurk::Middleware::Timeout.new.tap { |middleware| middleware.config = @capsule }
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

  def yielded_through_expiry?(fields)
    yielded = false
    expiry.call(nil, job(fields), 'q') { yielded = true }
    yielded
  end

  # The EXPIRED counter is a process-global singleton — serialize against every
  # other test class that reads or resets it.
  def with_expired_counter
    Wurk::Test::PROCESSOR_COUNTER_MUTEX.synchronize do
      Wurk::Processor::EXPIRED.reset
      yield
    end
  end

  # `Wurk::Metrics::Statsd.increment` is a process-global singleton method.
  def with_statsd_recorder
    Wurk::Test::STATSD_MUTEX.synchronize do
      calls = []
      real = Wurk::Metrics::Statsd.method(:increment)
      Wurk::Metrics::Statsd.singleton_class.send(:define_method, :increment) do |metric, tags: nil|
        calls << [metric, tags]
        nil
      end
      begin
        yield calls
      ensure
        Wurk::Metrics::Statsd.singleton_class.send(:define_method, :increment, real)
      end
    end
  end
end
