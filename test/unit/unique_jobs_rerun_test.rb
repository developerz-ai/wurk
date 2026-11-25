# frozen_string_literal: true

require_relative '../test_helper'

# Two runs of one jid at once, on real Redis: the first was interrupted (a
# deploy's hard shutdown, a crash, a partition) and its payload is running again
# elsewhere while it still unwinds. The lock admits the second run because it is
# the same job; from then on the lock is the second run's, and nothing the first
# one does on its way out may release or renew it.
#
# A Fiber stands in for each process: it stops inside `perform` and goes on when
# the test says so, so the order of events is exact.
class UniqueJobsRerunTest < Wurk::Test::UnitCase
  UJ = Wurk::UniqueJobs

  module Jobs
    class Running
      include Wurk::Job

      sidekiq_options lock: :while_executing, lock_ttl: 60, on_conflict: :log,
                      lock_args_method: ->(args) { [args[0]] }
    end

    class Pushed
      include Wurk::Job

      class << self
        attr_accessor :unlocked
      end

      sidekiq_options lock: :until_executed, lock_ttl: 60, on_conflict: :log,
                      lock_args_method: ->(args) { [args[0]] }

      def self.after_unlock = self.unlocked = unlocked.to_i + 1
    end

    class Both
      include Wurk::Job

      sidekiq_options lock: :until_and_while_executing, lock_ttl: 60, on_conflict: :log,
                      lock_args_method: ->(args) { [args[0]] }
    end

    class TwoAtOnce
      include Wurk::Job

      sidekiq_options lock: :while_executing, lock_limit: 2, lock_ttl: 60, on_conflict: :log,
                      lock_args_method: ->(args) { [args[0]] }
    end
  end

  # One run of a job, suspended inside `perform` by #start. `outcome` is what the
  # perform does when it goes on: raise it, or return.
  class Run
    attr_reader :item, :worker

    def initialize(server, payload, outcome)
      @item = Wurk.load_json(Wurk.dump_json(payload))
      @worker = Wurk.const_get(@item['class']).new
      @worker.jid = @item['jid']
      @entered = false
      @fiber = Fiber.new do
        server.invoke(@worker, @item, @item['queue']) do
          @entered = true
          Fiber.yield
          raise outcome if outcome
        end
        :returned
      end
    end

    def start = tap { @fiber.resume }
    def entered? = @entered

    def finish
      @fiber.resume
    rescue Wurk::Shutdown
      :unwound
    end
  end

  def setup
    super
    UJ.reset!
    Jobs::Pushed.unlocked = 0
    Wurk.configuration.client_middleware.add(UJ::Middleware::Client)
    @server = Wurk::Middleware::Chain.new(Wurk.configuration)
    @server.add(UJ::Middleware::Server)
  end

  def teardown
    Wurk.configuration.client_middleware.remove(UJ::Middleware::Client)
    UJ.reset!
  ensure
    super
  end

  # ---- helpers ------------------------------------------------------------

  def push(klass, *args) = Wurk::Client.push('class' => klass, 'args' => args)

  def payload(klass)
    raw = Wurk.redis { |c| c.call('LRANGE', 'queue:default', 0, -1) }
    raw.map { |json| Wurk.load_json(json) }.find { |job| job['class'] == klass.name }
  end

  def job_run(payload, outcome = nil) = Run.new(@server, payload, outcome)

  # The payload running again. until_and_while_executing leaves a wake token on
  # its push lock for 5 s, and no run of it starts past one: here they are over.
  def rerun(payload)
    Wurk.redis { |c| c.call('DEL', "#{payload['lock_digest'].delete_suffix(':RUN')}:QUEUED") }
    job_run(payload).start
  end

  def refresh!(...) = UJ.refresh_lock!(...)
  def other(payload) = payload.merge('jid' => 'other-jid')
  def holders(digest) = Wurk.redis { |c| c.call('HKEYS', "#{digest}:LOCKED") }
  def pttl(digest) = Wurk.redis { |c| c.call('PTTL', "#{digest}:LOCKED") }
  def shorten(digest) = Wurk.redis { |c| c.call('PEXPIRE', "#{digest}:LOCKED", 5_000) }
  def lock_keys = Wurk.redis { |c| c.call('KEYS', 'uniquejobs:*') }.grep(/(LOCKED|:RUN)\z/)

  # The digest its lock is under while the job performs.
  def held_digest(payload)
    digest = payload['lock_digest'].delete_suffix(':RUN')
    payload['lock'] == 'until_executed' ? digest : "#{digest}:RUN"
  end

  # ---- the incident -------------------------------------------------------

  # TREASURY-F1P: the re-run's lock survives the interrupted run's unwind, for
  # every type whose lock is held during `perform`.
  [Jobs::Running, Jobs::Both].each do |klass|
    name = klass.get_sidekiq_options['lock']

    define_method("test_#{name}_an_unwinding_run_leaves_the_reruns_lock_alone") do
      push(klass, 'acct-1')
      job = payload(klass)
      digest = held_digest(job)
      old = job_run(job, Wurk::Shutdown).start
      new = rerun(job)

      assert_predicate new, :entered?, 'the re-run must re-enter its own lock'
      assert_equal :unwound, old.finish
      assert_equal [job['jid']], holders(digest), 'the old run freed the lock the re-run holds'
      assert refresh!(new.worker), 'the re-run no longer passes as the holder'
      refute_predicate job_run(UJ::Job.prepare(other(job))).start, :entered?, 'a third job ran beside the re-run'

      new.finish

      assert_empty holders(digest), 'the re-run must release its own lock'
    end
  end

  # until_executed keeps its lock when interrupted; what releases it under the
  # re-run is an old run that finishes anyway.
  def test_until_executed_a_superseded_run_that_finishes_leaves_the_reruns_lock_alone
    push(Jobs::Pushed, 'acct-1')
    job = payload(Jobs::Pushed)
    old = job_run(job).start
    new = rerun(job)

    assert_equal :returned, old.finish
    assert_equal [job['jid']], holders(job['lock_digest']), 'the old run freed the lock the re-run holds'
    assert_nil push(Jobs::Pushed, 'acct-1'), 'a duplicate was accepted while the re-run performs'
    assert_equal 0, Jobs::Pushed.unlocked, 'after_unlock ran without an unlock'

    new.finish

    assert_empty holders(job['lock_digest'])
    assert_equal 1, Jobs::Pushed.unlocked
  end

  def test_until_executed_an_interrupted_run_keeps_the_lock_for_its_rerun
    push(Jobs::Pushed, 'acct-1')
    job = payload(Jobs::Pushed)
    old = job_run(job, Wurk::Shutdown).start
    new = rerun(job)
    old.finish

    assert refresh!(new.worker)
    new.finish

    assert_empty holders(job['lock_digest'])
  end

  # ---- refresh ------------------------------------------------------------

  [Jobs::Running, Jobs::Pushed, Jobs::Both].each do |klass|
    name = klass.get_sidekiq_options['lock']

    define_method("test_#{name}_a_superseded_run_cannot_refresh") do
      push(klass, 'acct-1')
      job = payload(klass)
      digest = held_digest(job)
      old = job_run(job).start

      assert refresh!(old.worker), 'the only run is the holder'
      new = rerun(job)
      shorten(digest)

      refute refresh!(old.worker), 'the superseded run passed as the holder, by instance'
      refute refresh!(old.item), 'the superseded run passed as the holder, by payload'
      assert_operator pttl(digest), :<=, 5_000, 'a superseded run extended the lock'
      assert refresh!(new.worker)
      assert refresh!(new.item)
      assert_operator pttl(digest), :>, 5_000
    ensure
      [old, new].compact.each(&:finish)
    end
  end

  # By jid alone two runs in one process cannot be told apart off their own
  # threads; the answer is the older one's, which is false: a holder that stops
  # is retried, an impostor that goes on writes beside it.
  def test_a_jid_shared_by_two_runs_in_one_process_never_passes_for_the_newer
    push(Jobs::Running, 'acct-1')
    job = payload(Jobs::Running)
    old = job_run(job).start
    new = rerun(job)

    refute ::Thread.new { refresh!(job['jid']) }.value

    old.finish

    assert refresh!(job['jid']), 'one run left: the jid is unambiguous again'
    new.finish
  end

  # The older run leaving must not take the newer one's entry with it.
  def test_the_old_run_ending_does_not_untrack_the_new_one
    push(Jobs::Running, 'acct-1')
    job = payload(Jobs::Running)
    old = job_run(job, Wurk::Shutdown).start
    new = rerun(job)
    old.finish

    assert refresh!(new.worker)
    assert refresh!(job['jid'])
    new.finish

    assert_raises(ArgumentError) { refresh!(job['jid']) }
  end

  # ---- crash recovery -----------------------------------------------------

  # A run that died without unwinding: its lock stays, and the same jid must get
  # back in, hold it and release it.
  [Jobs::Running, Jobs::Pushed, Jobs::Both].each do |klass|
    name = klass.get_sidekiq_options['lock']

    define_method("test_#{name}_crash_recovery_reenters_the_dead_runs_lock") do
      push(klass, 'acct-1')
      job = payload(klass)
      digest = held_digest(job)
      dead = job_run(job).start

      refute_predicate job_run(UJ::Job.prepare(other(job))).start, :entered?, 'another job took a held lock'
      recovered = rerun(job)

      assert_predicate recovered, :entered?, 'the recovered job could not re-enter its own lock'
      assert refresh!(recovered.item)
      assert_equal :returned, recovered.finish
      assert_empty holders(digest), 'the recovered run did not release the lock'
    ensure
      dead&.finish
    end
  end

  # Recovered twice: the newest run is the holder, whichever older one ends first.
  def test_each_rerun_supersedes_every_run_before_it
    push(Jobs::Running, 'acct-1')
    job = payload(Jobs::Running)
    runs = Array.new(3) { job_run(job, Wurk::Shutdown).start }

    held = runs.map { |r| refresh!(r.worker) }

    assert_equal [false, false, true], held
    runs[1].finish
    runs[0].finish

    assert refresh!(runs[2].worker)
    runs[2].finish

    assert_empty lock_keys
  end

  # ---- lost and re-taken --------------------------------------------------

  # The old run's lock expired and the re-run took a new one, rather than
  # re-entering: same jid, not the same lock.
  def test_a_run_whose_lock_expired_cannot_release_the_one_its_rerun_took
    push(Jobs::Running, 'acct-1')
    job = payload(Jobs::Running)
    digest = held_digest(job)
    old = job_run(job, Wurk::Shutdown).start
    UJ::Digests.new.delete_by_digest(job['lock_digest'].delete_suffix(':RUN'))
    new = rerun(job)
    old.finish

    assert_equal [job['jid']], holders(digest)
    assert refresh!(new.worker)
    new.finish
  end

  # The re-run is queued for the lock (QUEUED), not holding it yet: the old run's
  # unlock must not take its place in the line.
  def test_an_unwinding_run_without_its_lock_leaves_a_waiting_rerun_queued
    push(Jobs::Running, 'acct-1')
    job = payload(Jobs::Running)
    digest = held_digest(job)
    old = job_run(job, Wurk::Shutdown).start
    UJ::Digests.new.delete_by_digest(job['lock_digest'].delete_suffix(':RUN'))
    Wurk.redis { |c| c.call('LPUSH', "#{digest}:QUEUED", job['jid']) }
    old.finish

    assert_equal([job['jid']], Wurk.redis { |c| c.call('LRANGE', "#{digest}:QUEUED", 0, -1) })
  end

  def test_with_a_lock_limit_a_superseded_run_frees_neither_slot
    push(Jobs::TwoAtOnce, 'acct-1')
    job = payload(Jobs::TwoAtOnce)
    digest = held_digest(job)
    sibling = job_run(UJ::Job.prepare(other(job))).start
    old = job_run(job, Wurk::Shutdown).start
    new = rerun(job)
    old.finish

    assert_equal [job['jid'], 'other-jid'].sort, holders(digest).sort
    new.finish

    assert_equal ['other-jid'], holders(digest)
    sibling.finish

    assert_empty holders(digest)
  end

  # Two runs of one jid waiting together: the one that gets there second finds its
  # jid already in LOCKED and is the newer run all the same.
  def test_a_waiting_run_that_finds_its_jid_already_locked_becomes_the_holder
    key = UJ::Key.new('uniquejobs:rerun-duplicate')
    Wurk.redis { |c| c.call('HSET', key.locked, 'same', '1764000000.1') }
    argv = ['same', 0, 'while_executing', 1, '', 1_764_000_001.5, 0, 'lock.lua', '1764000001.5']
    Wurk.redis { |c| UJ::Script.call(:unique_jobs_lock, c, keys: key.to_a, argv: argv) }

    assert_equal('1764000001.5', Wurk.redis { |c| c.call('HGET', key.locked, 'same') })
  end

  # ---- the owed unlock ----------------------------------------------------

  # A run whose unlock met a Redis outage owes it to FinishedJobCleanup, which
  # sends it whenever Redis answers: by then the lock can be a later run's.
  [Jobs::Running, Jobs::Pushed].each do |klass|
    name = klass.get_sidekiq_options['lock']

    define_method("test_#{name}_an_owed_unlock_spares_the_run_that_superseded_it") do
      push(klass, 'acct-1')
      job = payload(klass)
      old = job_run(job).start
      new = rerun(job)
      settle(old.item)

      assert_equal [job['jid']], holders(held_digest(job)), 'the owed unlock freed the re-run\'s lock'
      assert refresh!(new.worker)
      new.finish
      old.finish
    end

    define_method("test_#{name}_an_owed_unlock_still_lands_when_nothing_superseded_it") do
      push(klass, 'acct-1')
      job = payload(klass)
      old = job_run(job).start
      settle(old.item)

      assert_empty holders(held_digest(job))
      old.finish
    end
  end

  # ---- beside processes that do not know about runs (the gem, Wurk <= 1.20) ---

  # An older process re-enters by jid and writes nothing: the lock still names
  # the run before, which is what its unwind then releases, as it always did.
  # What must hold is that nothing is stuck: the older process's unlock is by jid.
  def test_a_lock_this_version_holds_is_still_unlocked_by_jid
    push(Jobs::Running, 'acct-1')
    job = payload(Jobs::Running)
    job_run(job).start

    assert_equal job['jid'], UJ::Locksmith.new(job).unlock
    assert_empty holders(held_digest(job))
  end

  # A lock an older process left behind carries its lock time, not a run.
  def test_a_lock_an_older_process_left_is_reentered_renewed_and_released
    push(Jobs::Running, 'acct-1')
    job = payload(Jobs::Running)
    digest = held_digest(job)
    Wurk.redis { |c| c.call('HSET', "#{digest}:LOCKED", job['jid'], '1764000000.1234') }
    new = rerun(job)

    assert_predicate new, :entered?
    assert refresh!(new.worker)
    new.finish

    assert_empty holders(digest)
  end

  # LOCKED values stay what the gem writes and its dashboard reads: a Unix time.
  def test_the_locked_value_is_still_a_time
    push(Jobs::Running, 'acct-1')
    job = payload(Jobs::Running)
    old = job_run(job).start
    value = UJ::Lock.new(held_digest(job)).locked_jids(with_values: true).fetch(job['jid'])

    assert_match(/\A\d+\.\d+\z/, value)
    assert_in_delta Time.now.to_f, value.to_f, 5
    old.finish
  end

  # The run lives in this process only: the payload that goes back to Redis is
  # the one that came out of it.
  def test_the_payload_is_not_changed_by_its_run
    push(Jobs::Pushed, 'acct-1')
    job = payload(Jobs::Pushed)
    held = job_run(job).start

    assert_equal Wurk.dump_json(job), Wurk.dump_json(held.item)
    held.finish
  end

  private

  def settle(item)
    config = Wurk.configuration
    handlers = config.error_handlers.dup
    config.error_handlers.clear
    Wurk::FinishedJobCleanup.settle(item, RedisClient::CannotConnectError.new('down'),
                                    pool: config.default_capsule.redis_pool, config: config)
  ensure
    config.error_handlers.replace(handlers)
  end
end
