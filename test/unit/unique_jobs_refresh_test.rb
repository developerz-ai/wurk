# frozen_string_literal: true

require_relative '../test_helper'
require 'active_support/duration'

# Wurk::UniqueJobs.refresh_lock! on real Redis: a job pushed through the real
# client chain, run through the real server chain, renewing its own lock from
# inside the block that stands in for `perform`.
class UniqueJobsRefreshTest < Wurk::Test::UnitCase
  module Jobs
    class Submit
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_ttl: 60, lock_info: true, lock_args_method: ->(args) { [args[0]] }
    end

    class ProcessRaw
      include Wurk::Job

      sidekiq_options lock: :while_executing, lock_ttl: 60, on_conflict: :reschedule,
                      lock_args_method: ->(args) { [args[0]] }
    end

    class Scrape
      include Wurk::Job

      sidekiq_options lock: :until_and_while_executing, lock_ttl: 60, lock_args_method: ->(args) { [args[0]] }
    end

    class Starting
      include Wurk::Job

      sidekiq_options lock: :until_executing, lock_ttl: 60
    end

    class Expiring
      include Wurk::Job

      sidekiq_options lock: :until_expired, lock_ttl: 60
    end

    class Forever
      include Wurk::Job

      sidekiq_options lock: :until_executed
    end

    class Limited
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_limit: 2, lock_ttl: 60
    end

    # A type registered with `config.add_lock`: held from push until perform returns.
    class CustomLock < Wurk::UniqueJobs::Lock::UntilExecuted; end

    class Custom
      include Wurk::Job

      sidekiq_options lock: :custom_refresh, lock_ttl: 60
    end
  end

  def setup
    super
    Wurk::UniqueJobs.reset!
    Wurk::UniqueJobs.config.lock_timeout = nil
    Wurk.configuration.client_middleware.add(Wurk::UniqueJobs::Middleware::Client)
    @server = Wurk::Middleware::Chain.new(Wurk.configuration)
    @server.add(Wurk::UniqueJobs::Middleware::Server)
  end

  def teardown
    Wurk.configuration.client_middleware.remove(Wurk::UniqueJobs::Middleware::Client)
    Wurk::UniqueJobs.reset!
  ensure
    super
  end

  # ---- helpers ----------------------------------------------------------

  def push(klass, *args) = Wurk::Client.push('class' => klass, 'args' => args)

  def queued(klass)
    raw = Wurk.redis { |c| c.call('LRANGE', 'queue:default', 0, -1) }.reverse
    raw.map { |json| Wurk.load_json(json) }.select { |job| job['class'] == klass.name }
  end

  # Runs `job` through the server chain; the block gets the job instance, as
  # `perform` would be `self`.
  def perform(job)
    worker = Wurk.const_get(job['class']).new
    worker.jid = job['jid']
    ran = false
    @server.invoke(worker, job, job['queue']) do
      ran = true
      yield worker if block_given?
    end
    ran
  end

  def refresh!(...) = Wurk::UniqueJobs.refresh_lock!(...)
  def pttl(key) = Wurk.redis { |c| c.call('PTTL', key) }
  def shorten(*keys) = Wurk.redis { |c| keys.each { |key| c.call('PEXPIRE', key, 1_000) } }
  def locked_jids(digest) = Wurk.redis { |c| c.call('HKEYS', "#{digest}:LOCKED") }
  def lock_keys(digest) = Wurk.redis { |c| c.call('KEYS', "#{digest}*") }.reject { |k| k.end_with?(':QUEUED') }

  def assert_ttl_near(expected_ms, key)
    assert_in_delta expected_ms, pttl(key), 2_000, "#{key} has PTTL #{pttl(key)}, expected about #{expected_ms}"
  end

  # ---- until_executed -----------------------------------------------------

  def test_the_holder_renews_every_key_of_its_lock_to_the_lock_ttl
    push(Jobs::Submit, 'acct-1')
    job = queued(Jobs::Submit).first
    digest = job['lock_digest']
    keys = [digest, "#{digest}:LOCKED", "#{digest}:INFO"]
    results = []

    ran = perform(job) do |worker|
      shorten(*keys)
      results << refresh!(worker)

      keys.each { |key| assert_ttl_near 60_000, key }
    end

    assert ran
    assert_equal [true], results
    assert_empty lock_keys(digest), 'perform must still release the refreshed lock'
  end

  def test_an_explicit_ttl_wins_over_the_lock_ttl
    push(Jobs::Submit, 'acct-1')
    job = queued(Jobs::Submit).first
    digest = job['lock_digest']

    perform(job) do |worker|
      assert refresh!(worker, ttl: 3_600)
      [digest, "#{digest}:LOCKED", "#{digest}:INFO"].each { |key| assert_ttl_near 3_600_000, key }
      assert refresh!(worker, ttl: 1.5)
      assert_ttl_near 1_500, "#{digest}:LOCKED"
    end
  end

  def test_the_jid_and_the_payload_name_the_same_lock
    push(Jobs::Submit, 'acct-1')
    job = queued(Jobs::Submit).first

    perform(job) do |worker|
      assert refresh!(worker.jid, ttl: 120)
      assert_ttl_near 120_000, "#{job['lock_digest']}:LOCKED"
      assert refresh!(job, ttl: 240)
      assert_ttl_near 240_000, "#{job['lock_digest']}:LOCKED"
    end
  end

  # A long run renews from a thread of its own, by jid.
  def test_a_thread_started_inside_perform_can_refresh_by_jid
    push(Jobs::Submit, 'acct-1')
    job = queued(Jobs::Submit).first

    perform(job) do |worker|
      assert ::Thread.new { refresh!(worker.jid, ttl: 300) }.value
      assert_ttl_near 300_000, "#{job['lock_digest']}:LOCKED"
    end
  end

  def test_a_lock_taken_without_a_ttl_is_reported_held_and_left_without_one
    push(Jobs::Forever, 'acct-1')
    job = queued(Jobs::Forever).first

    perform(job) do |worker|
      assert refresh!(worker)
      assert_equal(-1, pttl("#{job['lock_digest']}:LOCKED"))
    end
  end

  def test_a_duration_ttl_is_seconds
    push(Jobs::Submit, 'acct-1')
    job = queued(Jobs::Submit).first

    perform(job) do |worker|
      assert refresh!(worker, ttl: ActiveSupport::Duration.minutes(15))
      assert_ttl_near 900_000, "#{job['lock_digest']}:LOCKED"
    end
  end

  # `lock_limit: 2` keeps both holders in one LOCKED hash: either may renew it,
  # and the renewal is the whole hash's.
  def test_with_a_lock_limit_each_holder_renews_the_shared_hash
    push(Jobs::Limited, 'acct-1')
    push(Jobs::Limited, 'acct-1')
    first, second = queued(Jobs::Limited)
    locked = "#{first['lock_digest']}:LOCKED"
    shorten(locked)

    assert refresh!(second, ttl: 300)
    assert_ttl_near 300_000, locked
    assert refresh!(first, ttl: 600)
    assert_ttl_near 600_000, locked
    refute refresh!(first.merge('jid' => 'third-jid'), ttl: 900)
    assert_equal [first['jid'], second['jid']].sort, locked_jids(first['lock_digest']).sort
  end

  def test_a_type_added_with_add_lock_renews_its_own_digest
    Wurk::UniqueJobs.config.add_lock(:custom_refresh, Jobs::CustomLock)
    push(Jobs::Custom, 'acct-1')
    job = queued(Jobs::Custom).first
    digest = job['lock_digest']

    refute digest.end_with?(':RUN')
    perform(job) do |worker|
      shorten("#{digest}:LOCKED")

      assert refresh!(worker)
      assert_ttl_near 60_000, "#{digest}:LOCKED"
    end
  end

  # ---- not the holder -----------------------------------------------------

  def test_another_jid_cannot_refresh_or_take_the_lock
    push(Jobs::Submit, 'acct-1')
    holder = queued(Jobs::Submit).first
    digest = holder['lock_digest']
    shorten(digest, "#{digest}:LOCKED")
    intruder = holder.merge('jid' => 'intruder-jid')

    refute refresh!(intruder, ttl: 3_600)
    assert_operator pttl("#{digest}:LOCKED"), :<=, 1_000, 'a non-holder extended the lock'
    assert_equal [holder['jid']], locked_jids(digest), 'a refresh must never take the lock'
  end

  def test_an_expired_lock_is_not_revived
    push(Jobs::Submit, 'acct-1')
    job = queued(Jobs::Submit).first
    digest = job['lock_digest']
    Wurk.redis { |c| [digest, "#{digest}:LOCKED", "#{digest}:INFO"].each { |key| c.call('PEXPIRE', key, 1) } }
    wait_until { lock_keys(digest).empty? }

    refute refresh!(job)
    assert_empty lock_keys(digest), 'a refresh recreated an expired lock'
    assert push(Jobs::Submit, 'acct-1'), 'the digest must be free for the next push'
  end

  def test_a_lock_now_held_by_a_later_job_stays_that_jobs
    push(Jobs::Submit, 'acct-1')
    stale = queued(Jobs::Submit).first
    Wurk::UniqueJobs::Digests.new.delete_by_digest(stale['lock_digest'])
    fresh = push(Jobs::Submit, 'acct-1')
    shorten("#{stale['lock_digest']}:LOCKED")

    refute refresh!(stale, ttl: 3_600)
    assert_equal [fresh], locked_jids(stale['lock_digest'])
    assert_operator pttl("#{stale['lock_digest']}:LOCKED"), :<=, 1_000
  end

  # ---- the other lock types -----------------------------------------------

  def test_while_executing_refreshes_its_runtime_lock
    push(Jobs::ProcessRaw, 'acct-1')
    job = queued(Jobs::ProcessRaw).first
    run = "#{job['lock_digest'].delete_suffix(':RUN')}:RUN"

    assert perform(job) { |worker|
      assert_equal [job['jid']], locked_jids(run)
      shorten(run, "#{run}:LOCKED")

      assert refresh!(worker.jid)
      assert_ttl_near 60_000, run
      assert_ttl_near 60_000, "#{run}:LOCKED"
    }
    assert_empty lock_keys(run)
  end

  # The concurrency case the API exists for: one run of an account holds the
  # runtime lock, a second jid for the same account can neither refresh it nor run.
  def test_while_executing_a_second_jid_for_the_same_digest_cannot_refresh
    push(Jobs::ProcessRaw, 'acct-1')
    push(Jobs::ProcessRaw, 'acct-1')
    holder, second = queued(Jobs::ProcessRaw)
    run = "#{holder['lock_digest'].delete_suffix(':RUN')}:RUN"

    perform(holder) do
      shorten("#{run}:LOCKED")

      refute refresh!(second, ttl: 3_600)
      refute perform(second.dup), 'the second run ran beside the holder'
      assert_operator pttl("#{run}:LOCKED"), :<=, 1_000
      assert_equal [holder['jid']], locked_jids(run)
    end
  end

  # During perform only the runtime lock is held; the push lock was handed over
  # as perform started, so a refresh renews `:RUN` and leaves the push digest free.
  def test_until_and_while_executing_refreshes_the_runtime_lock_only
    push(Jobs::Scrape, 'acct-1')
    job = queued(Jobs::Scrape).first
    digest = job['lock_digest']

    perform(job) do |worker|
      assert_empty locked_jids(digest), 'the push lock should be gone during perform'
      shorten("#{digest}:RUN:LOCKED")

      assert refresh!(worker)
      assert_ttl_near 60_000, "#{digest}:RUN:LOCKED"
      assert_empty locked_jids(digest), 'a refresh must not take the push lock back'
      assert push(Jobs::Scrape, 'acct-1'), 'the next push must still be accepted mid-run'
    end
  end

  def test_until_executing_holds_nothing_during_perform
    push(Jobs::Starting, 'acct-1')
    job = queued(Jobs::Starting).first

    perform(job) do |worker|
      refute refresh!(worker)
      assert_empty lock_keys(job['lock_digest'])
    end
  end

  def test_until_expired_moves_the_expiry_the_reaper_reads
    push(Jobs::Expiring, 'acct-1')
    job = queued(Jobs::Expiring).first
    digest = job['lock_digest']
    before = Wurk.redis { |c| c.call('ZSCORE', Wurk::UniqueJobs::EXPIRING_DIGESTS, digest) }.to_f
    shorten("#{digest}:LOCKED")

    perform(job) { |worker| assert refresh!(worker, ttl: 600) }
    after = Wurk.redis { |c| c.call('ZSCORE', Wurk::UniqueJobs::EXPIRING_DIGESTS, digest) }.to_f

    assert_operator after, :>, before
    assert_ttl_near 600_000, "#{digest}:LOCKED"
    assert_equal [job['jid']], locked_jids(digest), 'until_expired keeps its lock after perform'
  end

  def test_a_refresh_of_another_digest_leaves_the_expiry_index_alone
    push(Jobs::Submit, 'acct-1')
    job = queued(Jobs::Submit).first

    perform(job) { |worker| assert refresh!(worker) }

    expiring = Wurk.redis { |c| c.call('ZCARD', Wurk::UniqueJobs::EXPIRING_DIGESTS) }

    assert_equal 0, expiring
  end

  # ---- arguments ----------------------------------------------------------

  def test_a_jid_outside_its_perform_is_an_error
    push(Jobs::Submit, 'acct-1')
    job = queued(Jobs::Submit).first
    perform(job)

    error = assert_raises(ArgumentError) { refresh!(job['jid']) }
    assert_match(/no job "#{job['jid']}" is running/, error.message)
  end

  def test_bad_arguments_are_refused
    push(Jobs::Submit, 'acct-1')
    job = queued(Jobs::Submit).first

    [0, -5, 0.0001, '60', nil.to_a].each do |ttl|
      assert_raises(ArgumentError, "ttl #{ttl.inspect}") { refresh!(job, ttl: ttl) }
    end
    assert_raises(ArgumentError) { refresh!(job.except('lock_digest')) }
    assert_raises(ArgumentError) { refresh!(Object.new) }
    assert_raises(Wurk::UniqueJobs::UnknownLock) { refresh!(job.merge('lock' => 'no_such_lock')) }
  end

  private

  def wait_until(timeout: 5)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk 'condition not met in time' if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
      ::Thread.pass
    end
  end
end
