# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::UniqueJobs lock types and conflict strategies on real Redis, through the
# real client chain and a server chain invoked around a block that stands in for
# `perform`. The job shapes are the ones a payments/bank-sync app runs: until_executed
# with lock_args + reject, while_executing + reschedule, until_and_while_executing.
# A real worker runs the same in test/ecosystem/sidekiq-unique-jobs-native.
class UniqueJobsLocksTest < Wurk::Test::UnitCase
  module Jobs
    class Submit
      include Wurk::Job

      sidekiq_options queue: 'payments', lock: :until_executed, on_conflict: :reject, lock_args_method: :lock_args
      def self.lock_args(args) = [args[0]]
    end

    class ProcessRaw
      include Wurk::Job

      sidekiq_options lock: :while_executing, on_conflict: :reschedule, lock_args_method: ->(args) { [args[0]] }
    end

    class Scrape
      include Wurk::Job

      sidekiq_options lock: :until_and_while_executing, on_conflict: :reject, lock_args_method: ->(args) { [args[0]] }
    end

    class Reapply
      include Wurk::Job

      sidekiq_options lock: :until_executed, on_conflict: :reschedule, schedule_in: 30
    end

    class Starting
      include Wurk::Job

      sidekiq_options lock: :until_executing, on_conflict: :log
    end

    class Expiring
      include Wurk::Job

      sidekiq_options lock: :until_expired, lock_ttl: 60
    end

    class Raising
      include Wurk::Job

      sidekiq_options lock: :until_executed, on_conflict: :raise
    end

    class Replacing
      include Wurk::Job

      sidekiq_options lock: :until_executed, on_conflict: :replace
    end

    # Pushes its continuation from `after_unlock`, once its own lock is gone.
    class Chain
      include Wurk::Job

      sidekiq_options lock: :until_executed, on_conflict: :reject, lock_args_method: ->(args) { [args[0]] }

      def perform(_slice, step)
        @next = step + 1 if step < 2
      end

      def after_unlock
        self.class.perform_async(1, @next) if @next
      end
    end

    class Split
      include Wurk::Job

      sidekiq_options lock: :until_executed, on_conflict: { client: :log, server: :reject }
    end
  end

  def setup
    super
    Wurk::UniqueJobs.reset!
    Wurk::UniqueJobs.config.lock_ttl = 7200
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

  def push(klass, *args, queue: nil, at: nil)
    item = { 'class' => klass, 'args' => args }
    item['queue'] = queue if queue
    item['at'] = at if at
    Wurk::Client.push(item)
  end

  # The payloads as a worker gets them, oldest first: the JSON the client wrote.
  def queued(klass)
    queue = klass.get_sidekiq_options['queue'] || 'default'
    raw = Wurk.redis { |c| c.call('LRANGE', "queue:#{queue}", 0, -1) }.reverse
    raw.map { |json| Wurk.load_json(json) }.select { |job| job['class'] == klass.name }
  end

  def perform(job, &block)
    block ||= -> {}
    ran = false
    @server.invoke(Wurk.const_get(job['class']).new, job, job['queue']) do
      ran = true
      block.call
    end
    ran
  end

  def digest_of(job) = job['lock_digest'].delete_suffix(':RUN')
  def locked_jids(digest) = Wurk.redis { |c| c.call('HKEYS', "#{digest}:LOCKED") }

  # An unlock leaves a 5-second "1" in QUEUED to wake a waiter, as the gem's does.
  def lock_keys
    keys = Wurk.redis { |c| c.call('KEYS', 'uniquejobs:*') }
    keys.reject { |k| k == 'uniquejobs:changelog' || k.end_with?(':QUEUED') }
  end

  def dead = Wurk::DeadSet.new
  def scheduled = Wurk::ScheduledSet.new

  # ---- until_executed ---------------------------------------------------

  def test_until_executed_reject_refuses_the_same_lock_args_and_buries_the_duplicate
    first = push(Jobs::Submit, 42, 'order-a')

    assert first
    assert_nil push(Jobs::Submit, 42, 'order-b')
    assert_equal 1, dead.size
    assert_equal [42, 'order-b'], dead.first.args
    assert push(Jobs::Submit, 43, 'order-a'), 'other lock args were refused'
    assert_equal [first], locked_jids(queued(Jobs::Submit).first['lock_digest'])
  end

  def test_the_rejected_duplicate_leaves_the_holders_lock_alone
    handlers = Wurk.configuration.death_handlers
    handlers << Wurk::UniqueJobs::Server::DEATH_HANDLER
    holder = push(Jobs::Submit, 1)
    push(Jobs::Submit, 1)

    assert_equal [holder], locked_jids(queued(Jobs::Submit).first['lock_digest'])
  ensure
    handlers.delete(Wurk::UniqueJobs::Server::DEATH_HANDLER)
  end

  def test_until_executed_unlocks_after_perform_and_keeps_the_lock_through_a_failure
    push(Jobs::Submit, 7)
    job = queued(Jobs::Submit).first

    assert_raises(RuntimeError) { perform(job) { raise 'bank timeout' } }
    assert_equal [job['jid']], locked_jids(job['lock_digest']), 'the lock must hold while the job waits to retry'
    assert_nil push(Jobs::Submit, 7)

    assert perform(job), 'the retry must run under its own lock'
    assert_empty lock_keys
    assert push(Jobs::Submit, 7)
  end

  # A job whose lock went to another jid while it waited does not run.
  def test_until_executed_skips_perform_when_another_job_holds_the_lock
    push(Jobs::Submit, 9)
    job = queued(Jobs::Submit).first
    Wurk::UniqueJobs::Digests.new.delete_by_digest(job['lock_digest'])
    other = job.merge('jid' => 'other-jid')
    Wurk::UniqueJobs::Locksmith.new(other).lock

    refute perform(job)
  end

  def test_death_releases_the_lock
    push(Jobs::Submit, 5)
    job = queued(Jobs::Submit).first
    Wurk::UniqueJobs::Server::DEATH_HANDLER.call(job, RuntimeError.new('dead'))

    assert_empty lock_keys
    assert push(Jobs::Submit, 5)
  end

  def test_a_scheduled_job_keeps_its_lock_through_the_wait_and_its_promotion
    jid = push(Jobs::Submit, 3, at: Time.now.to_f + 600)
    digest = Wurk.load_json(scheduled.first.value)['lock_digest']
    ttl = Wurk.redis { |c| c.call('PTTL', "#{digest}:LOCKED") }

    assert_operator ttl, :>, 7_200_000, 'the TTL must cover the wait as well'
    assert_nil push(Jobs::Submit, 3)
    # Promotion runs the client chain again with the job's own jid.
    promoted = Wurk.load_json(scheduled.first.value).except('at')

    assert Wurk::Client.push(promoted)
    assert_equal [jid], locked_jids(digest)
  end

  def test_until_executed_reschedule_pushes_the_duplicate_later_without_a_lock
    holder = push(Jobs::Reapply, 11)

    assert_nil push(Jobs::Reapply, 11)
    entry = scheduled.first

    assert_equal [11], entry.args
    assert_in_delta Time.now.to_f + 30, entry.at.to_f, 2
    refute entry.item.key?('rescheduled'), 'the bypass flag must not reach the payload'
    refute entry.item.key?('lock_digest'), 'the rescheduled push takes no lock'
    assert_equal [holder], locked_jids(queued(Jobs::Reapply).first['lock_digest'])
  end

  # As in the gem: the rescheduled copy takes the lock when it runs, so it runs
  # only if the holder is done by then; while the holder still holds, it is dropped.
  def test_a_rescheduled_until_executed_copy_runs_only_once_the_holder_is_done
    push(Jobs::Reapply, 12)
    holder = queued(Jobs::Reapply).first
    push(Jobs::Reapply, 12)
    copy = Wurk.load_json(scheduled.first.value)

    refute perform(copy.dup), 'the copy ran beside the holder'
    assert perform(holder)
    assert perform(copy.dup), 'the copy did not run after the holder finished'
    assert_empty lock_keys
  end

  # The hook runs on the job instance after its lock is released, so a push of
  # the same lock args from there is accepted.
  def test_after_unlock_on_the_instance_can_push_the_continuation
    push(Jobs::Chain, 1, 0)
    job = queued(Jobs::Chain).first
    instance = Jobs::Chain.new
    @server.invoke(instance, job, job['queue']) { instance.perform(*job['args']) }

    assert_equal([[1, 0], [1, 1]], queued(Jobs::Chain).map { |j| j['args'] })
  end

  # ---- until_executing --------------------------------------------------

  def test_until_executing_unlocks_before_perform_and_relocks_on_failure
    push(Jobs::Starting, 1)
    job = queued(Jobs::Starting).first
    during = nil

    assert_raises(RuntimeError) do
      perform(job) do
        during = locked_jids(job['lock_digest'])
        raise 'boom'
      end
    end
    assert_empty during
    assert_equal [job['jid']], locked_jids(job['lock_digest'])
  end

  # ---- while_executing --------------------------------------------------

  def test_while_executing_takes_no_lock_at_push_and_reschedules_a_concurrent_copy
    push(Jobs::ProcessRaw, 'session-1', 'chunk-a')
    push(Jobs::ProcessRaw, 'session-1', 'chunk-b')
    first, second = queued(Jobs::ProcessRaw)

    assert_empty lock_keys
    second_ran = nil
    perform(first) do
      # The client already wrote the runtime digest into the payload, as the gem does.
      assert_equal "#{digest_of(first)}:RUN", first['lock_digest']
      assert_equal [first['jid']], locked_jids(first['lock_digest'])
      second_ran = perform(second)
    end

    refute second_ran, 'two copies ran at once'
    assert_equal [%w[session-1 chunk-b]], scheduled.map(&:args)
    assert_empty lock_keys
    assert perform(Wurk.load_json(scheduled.first.value)), 'the rescheduled copy runs once the first is done'
  end

  def test_while_executing_unlocks_when_perform_raises
    push(Jobs::ProcessRaw, 's')
    job = queued(Jobs::ProcessRaw).first

    assert_raises(RuntimeError) { perform(job) { raise 'x' } }
    assert_empty lock_keys
  end

  # ---- until_and_while_executing ----------------------------------------

  def test_until_and_while_executing_hands_the_push_lock_to_a_runtime_lock
    holder = push(Jobs::Scrape, 'conn-1')

    assert_nil push(Jobs::Scrape, 'conn-1'), 'the push lock held'
    assert_equal 1, dead.size
    job = queued(Jobs::Scrape).first
    during = nil
    perform(job) do
      during = push(Jobs::Scrape, 'conn-1')
      second = queued(Jobs::Scrape).last

      refute perform(second), 'the runtime lock let a second copy run'
    end

    assert during, 'the push lock must be off while the job runs'
    assert_equal 2, dead.size, 'the copy refused at runtime goes to the dead set'
    assert_equal holder, job['jid']
  end

  def test_until_and_while_executing_takes_the_push_lock_back_when_perform_raises
    push(Jobs::Scrape, 'conn-2')
    job = queued(Jobs::Scrape).first

    assert_raises(RuntimeError) { perform(job) { raise 'login failed' } }
    assert_equal [job['jid']], locked_jids(job['lock_digest'])
    assert_empty locked_jids("#{job['lock_digest']}:RUN")
    assert_nil push(Jobs::Scrape, 'conn-2'), 'a duplicate got in while the job waits to retry'
  end

  # ---- until_expired ----------------------------------------------------

  def test_until_expired_outlives_perform_until_its_ttl
    push(Jobs::Expiring, 1)
    job = queued(Jobs::Expiring).first

    assert perform(job)
    assert_equal [job['jid']], locked_jids(job['lock_digest'])
    assert_nil push(Jobs::Expiring, 1)
    score = Wurk.redis { |c| c.call('ZSCORE', 'uniquejobs:expiring_digests', job['lock_digest']) }.to_f

    assert_in_delta Time.now.to_f + 60_000, score, 5_000
    assert_operator Wurk.redis { |c| c.call('PTTL', job['lock_digest']) }, :<=, 60_000
  end

  # ---- the other strategies ---------------------------------------------

  def test_raise_strategy_raises_conflict
    push(Jobs::Raising, 1)
    error = assert_raises(Wurk::UniqueJobs::Conflict) { push(Jobs::Raising, 1) }

    assert_match(/uniquejobs:\h+ is already scheduled or processing/, error.message)
  end

  def test_replace_strategy_swaps_the_queued_holder_for_the_new_push
    old = push(Jobs::Replacing, 1, queue: 'default')
    new = push(Jobs::Replacing, 1, queue: 'default')

    assert new
    refute_equal old, new
    assert_equal([new], queued(Jobs::Replacing).map { |j| j['jid'] })
    assert_equal [new], locked_jids(queued(Jobs::Replacing).first['lock_digest'])
  end

  def test_log_strategy_drops_quietly_and_hash_form_splits_client_and_server
    push(Jobs::Split, 1)

    assert_nil push(Jobs::Split, 1)
    assert_equal 0, dead.size
    holder = queued(Jobs::Split).first
    intruder = holder.merge('jid' => 'intruder')

    refute perform(intruder)
    assert_equal 0, dead.size, 'until_executed has no server conflict to send anywhere'
  end

  # ---- switches -----------------------------------------------------------

  def test_disabled_config_takes_no_lock
    Wurk::UniqueJobs.config.enabled = false
    push(Jobs::Submit, 1)

    assert push(Jobs::Submit, 1)
    assert_empty lock_keys
  end

  def test_a_job_without_lock_passes_through
    klass = Class.new { include Wurk::Job }
    self.class.const_set(:Plain, klass)

    assert push(klass, 1)
    assert push(klass, 1)
    assert_empty lock_keys
  ensure
    self.class.send(:remove_const, :Plain)
  end

  def test_digests_api_lists_and_deletes
    push(Jobs::Submit, 1)
    push(Jobs::Submit, 2)
    digests = Wurk::UniqueJobs::Digests.new

    assert_equal 2, digests.count
    total, _cursor, page = digests.page(page_size: 10)

    assert_equal 2, total
    assert_kind_of Wurk::UniqueJobs::Lock, page.first
    assert_equal 2, digests.delete_by_pattern('*')
    assert_empty lock_keys
  end

  def test_changelog_records_only_with_history
    Wurk::UniqueJobs.config.max_history = 0
    push(Jobs::Submit, 1)

    assert_equal(0, Wurk.redis { |c| c.call('ZCARD', 'uniquejobs:changelog') })
    Wurk::UniqueJobs.config.max_history = 10
    push(Jobs::Submit, 2)
    entries = Wurk::UniqueJobs::Changelog.new.entries

    assert_equal(['Locked'], entries.map { |e| e['message'] })
    assert_equal 'queue_and_lock.lua', entries.first['script']
  end
end
