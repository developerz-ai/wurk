# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'
require 'wurk/unique_jobs_compat'

# Wurk's two corrections to sidekiq-unique-jobs, on stand-ins for the gem's
# classes (the gem is not in this bundle). The real gem runs in
# test/ecosystem/sidekiq-unique-jobs/lock_scenarios.rb.
class UniqueJobsCompatTest < Wurk::Test::UnitCase
  parallelize_me!

  class FakeReaper
    def belongs_to_job?(_digest) = false
    prepend Wurk::UniqueJobsCompat::PrivateListsAreLive
  end

  class FakeVersion
    class << self
      attr_accessor :error

      def call
        raise error if error

        true
      end
      prepend Wurk::UniqueJobsCompat::VersionWriteIsOptional
    end
  end

  def setup
    super
    @digest = "uniquejobs:#{SecureRandom.hex(16)}"
    @key = "queue:compat-#{SecureRandom.hex(4)}|host|123|0123456789ab|0"
    @log = StringIO.new
    @logger = Wurk.logger
    Wurk.logger = ::Logger.new(@log)
    FakeVersion.error = nil
  end

  def teardown
    Wurk.redis { |c| c.call('DEL', @key) }
    Wurk.logger = @logger
  ensure
    super
  end

  def test_a_job_in_a_private_list_keeps_its_lock
    push(@key, @digest)

    assert FakeReaper.new.belongs_to_job?(@digest)
  end

  def test_a_job_in_a_pro_private_list_keeps_its_lock
    @key = "queue:sq|host:123:0123456789ab|compat-#{SecureRandom.hex(4)}"
    push(@key, @digest)

    assert FakeReaper.new.belongs_to_job?(@digest)
  end

  def test_a_run_lock_is_matched_on_its_base_digest
    push(@key, @digest)

    assert FakeReaper.new.belongs_to_job?("#{@digest}:RUN")
  end

  def test_a_lock_with_no_job_anywhere_is_still_an_orphan
    push(@key, "uniquejobs:#{SecureRandom.hex(16)}")

    refute FakeReaper.new.belongs_to_job?(@digest)
  end

  # The list is read per digest: a job moved in after the first check counts.
  def test_a_job_arriving_after_the_first_check_is_seen
    reaper = FakeReaper.new
    push(@key, "uniquejobs:#{SecureRandom.hex(16)}")

    refute reaper.belongs_to_job?(@digest)
    push(@key, @digest)

    assert reaper.belongs_to_job?(@digest)
  end

  ['OOM command not allowed when used memory > maxmemory.',
   'Error running script (call to 138b): @user_script:63: -ERR Out of memory'].each_with_index do |message, index|
    define_method(:"test_an_oom_on_the_version_write_does_not_stop_boot_#{index}") do
      FakeVersion.error = RedisClient::CommandError.new(message)

      refute FakeVersion.call
      assert_includes @log.string, 'uniquejobs:live'
      assert_includes @log.string, Wurk::UniqueJobsCompat.gem_version
    end
  end

  # What the gem raises for a script that failed: not a RedisClient error.
  def test_an_oom_wrapped_by_the_gem_does_not_stop_boot
    FakeVersion.error = RuntimeError.new('update_version.lua:63: -ERR Out of memory')

    refute FakeVersion.call
  end

  def test_any_other_error_on_the_version_write_still_raises
    FakeVersion.error = RedisClient::CommandError.new('WRONGTYPE Operation against a key')

    assert_raises(RedisClient::CommandError) { FakeVersion.call }
  end

  def test_a_connection_error_on_the_version_write_still_raises
    FakeVersion.error = RedisClient::CannotConnectError.new('down')

    assert_raises(RedisClient::CannotConnectError) { FakeVersion.call }
  end

  def test_install_without_the_gem_does_nothing
    assert_nil Wurk::UniqueJobsCompat.install unless defined?(::SidekiqUniqueJobs::Orphans::RubyReaper)
  end

  private

  def push(key, digest)
    Wurk.redis { |c| c.call('LPUSH', key, Wurk.dump_json('class' => 'J', 'jid' => 'j', 'lock_digest' => digest)) }
  end
end
