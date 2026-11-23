# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'
require 'wurk/unique_jobs_compat'

# Wurk's two corrections to sidekiq-unique-jobs, on stand-ins for the gem's
# classes (the gem is not in this bundle). The real gem runs in
# test/ecosystem/sidekiq-unique-jobs/lock_scenarios.rb.
class UniqueJobsCompatTest < Wurk::Test::UnitCase
  parallelize_me!

  # The gem's selection, reduced to what the guard wraps: candidates are decided
  # (`classify` runs where the gem walks its digests), then handed to deletion.
  class FakeReaper
    attr_accessor :candidates, :classify

    def orphans
      kept = candidates.reject { |digest| belongs_to_job?(digest) }
      classify&.call
      kept
    end

    def belongs_to_job?(_digest) = false
    prepend Wurk::UniqueJobsCompat::PrivateListsAreLive
  end

  # Counts LRANGE on the wire, pipelined or not.
  module LrangeCounter
    class << self
      attr_accessor :count
    end

    def call(*command, **)
      LrangeCounter.count = LrangeCounter.count.to_i + 1 if command.first == 'LRANGE'
      super
    end
  end
  RedisClient::Pipeline.prepend(LrangeCounter)

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

  def test_a_job_in_a_dead_private_list_keeps_its_lock
    push(@key, @digest)

    assert_empty reaper_for(@digest).orphans
  end

  def test_a_job_in_a_pro_private_list_keeps_its_lock
    @key = "queue:sq|host:123:0123456789ab|compat-#{SecureRandom.hex(4)}"
    push(@key, @digest)

    assert_empty reaper_for(@digest).orphans
  end

  def test_a_run_lock_is_matched_on_its_base_digest
    push(@key, @digest)

    assert_empty reaper_for("#{@digest}:RUN").orphans
  end

  def test_a_lock_with_no_job_anywhere_is_still_an_orphan
    push(@key, "uniquejobs:#{SecureRandom.hex(16)}")

    assert_equal [@digest], reaper_for(@digest).orphans
  end

  def test_a_digest_sharing_a_prefix_does_not_protect_the_wrong_lock
    push(@key, "#{@digest}ff")

    assert_equal [@digest], reaper_for(@digest).orphans
  end

  # Fetched after the gem looked at the public queues: only the read after
  # classification can see it.
  def test_a_job_fetched_during_classification_keeps_its_lock
    reaper = reaper_for(@digest)
    reaper.classify = -> { push(@key, @digest) }

    assert_empty reaper.orphans
  end

  # Reclaimed to its public queue after the gem looked there: only the read
  # before classification can see it.
  def test_a_job_reclaimed_during_classification_keeps_its_lock
    push(@key, @digest)
    reaper = reaper_for(@digest)
    reaper.classify = -> { Wurk.redis { |c| c.call('DEL', @key) } }

    assert_empty reaper.orphans
  end

  def test_the_lists_are_read_a_fixed_number_of_times_however_many_digests
    push(@key, "uniquejobs:#{SecureRandom.hex(16)}")

    assert_equal lranges_for(2), lranges_for(500)
  end

  def test_a_failed_read_deletes_nothing
    reaper = reaper_for(@digest)
    original = Wurk.method(:redis)
    Wurk.define_singleton_method(:redis) { |**, &| raise RedisClient::CannotConnectError, 'down' }

    assert_raises(RedisClient::CannotConnectError) { reaper.orphans }
  ensure
    Wurk.define_singleton_method(:redis, original)
  end

  def test_a_failure_on_the_second_read_deletes_nothing
    reaper = reaper_for(@digest)
    original = Wurk.method(:redis)
    reaper.classify = -> { Wurk.define_singleton_method(:redis) { |**, &| raise RedisClient::ReadTimeoutError, 'slow' } }

    assert_raises(RedisClient::ReadTimeoutError) { reaper.orphans }
  ensure
    Wurk.define_singleton_method(:redis, original)
  end

  def test_an_unparseable_payload_keeps_the_lock_it_names_and_is_counted
    Wurk.redis { |c| c.call('LPUSH', @key, %({"class":"J","lock_digest":"#{@digest}","args":[)) }

    assert_empty reaper_for(@digest).orphans
    assert_includes @log.string, '1 unreadable'
  end

  def test_an_unparseable_payload_does_not_protect_a_lock_it_does_not_name
    Wurk.redis { |c| c.call('LPUSH', @key, '{not json') }

    assert_equal [@digest], reaper_for(@digest).orphans
  end

  def test_a_legacy_unique_digest_field_keeps_its_lock
    Wurk.redis { |c| c.call('LPUSH', @key, Wurk.dump_json('class' => 'J', 'unique_digest' => @digest)) }

    assert_empty reaper_for(@digest).orphans
  end

  def test_a_public_queue_with_a_pipe_in_its_name_is_not_read
    name = "compat|#{SecureRandom.hex(4)}|123|0123456789ab|0"
    @key = "queue:#{name}"
    Wurk.redis { |c| c.call('SADD', Wurk::Keys::QUEUES_SET, name) }
    push(@key, @digest)

    assert_equal [@digest], reaper_for(@digest).orphans
  ensure
    Wurk.redis { |c| c.call('SREM', Wurk::Keys::QUEUES_SET, name) }
  end

  def test_a_key_that_is_not_a_private_list_is_not_read
    @key = "queue:foreign|#{SecureRandom.hex(4)}"
    push(@key, @digest)

    assert_equal [@digest], reaper_for(@digest).orphans
  end

  # Reads as both a Pro and a Wurk list, so the fetcher will not reclaim it, but
  # its job is real.
  def test_a_list_the_fetcher_refuses_as_ambiguous_still_protects_its_job
    @key = "queue:sq|host:123:0123456789ab|2024|#{rand(1000..9999)}"
    push(@key, @digest)

    assert_empty reaper_for(@digest).orphans
  end

  def test_a_list_longer_than_a_page_is_read_to_its_end
    digests = Array.new(12) { "uniquejobs:#{SecureRandom.hex(16)}" }
    digests.each { |digest| push(@key, digest) }

    assert_equal digests.to_set, page_reader.call.digests
  end

  # Entries removed between two pages shift the rest past the read position.
  def test_a_list_shifting_past_the_page_overlap_aborts_the_read
    12.times { push(@key, "uniquejobs:#{SecureRandom.hex(16)}") }
    reader = page_reader
    key = @key
    reader.singleton_class.prepend(Module.new do
      define_method(:read_page) do |list, start|
        Wurk.redis { |c| c.call('LPOP', key, 5) }
        super(list, start)
      end
    end)

    assert_raises(Wurk::UniqueJobsCompat::PrivateListDigests::ListMoved) { reader.call }
  end

  def test_a_guard_without_the_gems_method_says_so_and_is_not_applied
    reaper = Class.new

    Wurk::UniqueJobsCompat.guard_reaper(reaper)

    refute_includes reaper.ancestors, Wurk::UniqueJobsCompat::PrivateListsAreLive
    assert_includes @log.string, 'has no RubyReaper#orphans'
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
    assert_nil Wurk::UniqueJobsCompat.install
    assert Object.autoload?(:SidekiqUniqueJobs), 'asking loaded the native copy'
  end

  private

  def reaper_for(*digests)
    FakeReaper.new.tap { |reaper| reaper.candidates = digests }
  end

  def page_reader
    Wurk::UniqueJobsCompat::PrivateListDigests.new(page: 5, overlap: 2)
  end

  def lranges_for(count)
    LrangeCounter.count = 0
    reaper_for(*Array.new(count) { "uniquejobs:#{SecureRandom.hex(16)}" }).orphans
    LrangeCounter.count
  end

  def push(key, digest)
    Wurk.redis { |c| c.call('LPUSH', key, Wurk.dump_json('class' => 'J', 'jid' => 'j', 'lock_digest' => digest)) }
  end
end
