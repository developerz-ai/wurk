# frozen_string_literal: true

require_relative '../test_helper'

# Who answers to `SidekiqUniqueJobs`: Wurk's native copy when the gem is not in
# the bundle, the gem when it is, and never both. Each case runs in a fork:
# loading the alias prepends the API extension onto Wurk::JobSet and friends,
# which would leak into every other test in this worker.
class UniqueJobsActivationTest < Wurk::Test::UnitCase
  class LockedJob
    include Wurk::Job

    sidekiq_options lock: :until_executed, lock_args_method: ->(args) { [args[0]] }
  end

  # Runs the block in a child; returns what it returned, re-raising its failure.
  def in_fork
    reader, writer = IO.pipe
    [reader, writer].each(&:binmode)
    pid = fork do
      reader.close
      result = begin
        [:ok, yield]
      rescue Exception => e # rubocop:disable Lint/RescueException -- reported to the parent, which raises it
        [:error, "#{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"]
      end
      writer.write(Marshal.dump(result.map { |v| v.is_a?(Module) ? v.name : v }))
      writer.close
      exit!(0)
    end
    writer.close
    data = reader.read
    _, child = Process.wait2(pid)
    flunk("the child wrote nothing and exited #{child.inspect}") if data.empty?
    status, value = Marshal.load(data) # rubocop:disable Security/MarshalLoad -- our own child
    flunk(value) if status == :error
    value
  end

  def test_without_the_gem_the_constant_and_requires_are_native
    result = in_fork do
      require 'sidekiq-unique-jobs'
      require 'sidekiq_unique_jobs'
      [SidekiqUniqueJobs.name, Wurk::UniqueJobs.native?, $LOAD_PATH.last == Wurk::UniqueJobsCompat::REQUIRE_PATH,
       SidekiqUniqueJobs::VERSION, SidekiqUniqueJobs::Lock::Validator::DEPRECATED_KEYS.size]
    end

    assert_equal ['Wurk::UniqueJobs', true, true, '8.1.0', 4], result
  end

  # The gem's `sidekiq_unique_ext`: a job deleted through the API gives its lock back.
  def test_deleting_a_job_through_the_api_releases_its_lock
    released = in_fork do
      SidekiqUniqueJobs.config.lock_ttl = 600
      Wurk.configuration.client_middleware.add(SidekiqUniqueJobs::Middleware::Client)
      push = ->(*args, **opts) { Wurk::Client.push({ 'class' => LockedJob, 'args' => args }.merge(opts)) }

      push.call('held', 'a')
      push.call('queued', 'a')
      Sidekiq::Queue.new('default').each { |job| job.delete if job.args.first == 'queued' }
      push.call('scheduled', 'a', 'at' => Time.now.to_f + 60)
      Sidekiq::ScheduledSet.new.first.delete
      push.call('cleared', 'a', 'queue' => 'parked')
      Sidekiq::Queue.new('parked').clear
      [push.call('queued', 'b'), push.call('scheduled', 'b'), push.call('cleared', 'b', 'queue' => 'parked'),
       push.call('held', 'b')].map { |jid| !jid.nil? }
    end

    assert_equal [true, true, true, false], released, 'deleted jobs free their locks; a queued one keeps it'
  end

  def test_with_the_gem_in_the_bundle_native_stays_out_of_the_way
    result = in_fork do
      Object.send(:remove_const, :SidekiqUniqueJobs) if Object.autoload?(:SidekiqUniqueJobs)
      Gem.loaded_specs['sidekiq-unique-jobs'] = Gem::Specification.new('sidekiq-unique-jobs', '8.1.0')
      Wurk::UniqueJobs.instance_variable_set(:@native, nil)
      log = StringIO.new
      Wurk::UniqueJobs.config.logger = Logger.new(log)
      activated = Wurk::UniqueJobsCompat.activate_native
      chain = Wurk::Middleware::Chain.new(Wurk.configuration)
      chain.add(Wurk::UniqueJobs::Middleware::Client)
      item = { 'class' => LockedJob.name, 'queue' => 'default', 'args' => [1], 'jid' => 'j' }
      2.times { chain.invoke(LockedJob.name, item.dup, 'default', nil) { :pushed } }
      [activated, Object.autoload?(:SidekiqUniqueJobs), Wurk::UniqueJobs.native?,
       Wurk.redis { |c| c.call('KEYS', 'uniquejobs:*') }, log.string.scan('gem is loaded').size]
    end

    assert_equal [:gem, nil, false, [], 1], result
  end

  # Without Bundler a gem can be activated after Wurk set the native copy up;
  # its `module SidekiqUniqueJobs` must fail loudly, not reopen the native one.
  def test_a_gem_activated_after_wurk_raises
    message = in_fork do
      raise 'the native copy was loaded in this test worker, outside a fork' unless Object.autoload?(:SidekiqUniqueJobs)

      Gem.loaded_specs['sidekiq-unique-jobs'] = Gem::Specification.new('sidekiq-unique-jobs', '8.1.0')
      SidekiqUniqueJobs
    rescue LoadError => e
      e.message
    end

    assert_match(/activated after Wurk/, message)
  end

  def test_boot_check_names_lock_jobs_only_without_a_client_middleware
    out = StringIO.new
    logger = Logger.new(out)
    chain = Wurk::Middleware::Chain.new(Wurk.configuration)
    Wurk::BootChecks.warn_on_ignored_locks(logger, chain)

    assert_match(/UniqueJobsActivationTest::LockedJob/, out.string)
    chain.add(Wurk::UniqueJobs::Middleware::Client)
    out.truncate(0)
    Wurk::BootChecks.warn_on_ignored_locks(logger, chain)

    assert_empty out.string
  end
end
