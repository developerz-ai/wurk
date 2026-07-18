# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/controllers/wurk/api/serializers'

# Custom job-info rows (spec §25.2) flow from the host-registered
# Wurk::Web.config.custom_job_info_rows into the job-record JSON the SPA renders
# in its detail modal. Each test mutates the global Wurk::Web.config singleton;
# setup/teardown reset it, and minitest-parallel_fork isolates the class in its
# own process and runs its tests serially, so the shared config is safe.
class ApiSerializersTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    Wurk::Web.reset_config!
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def test_job_record_omits_custom_rows_when_none_registered
    refute_includes Wurk::Api::Serializers.job_record(record).keys, :custom_rows
  end

  def test_job_record_includes_rows_from_callable_extensions
    Wurk::Web.config.custom_job_info_rows << ->(job) { ['Status', "queued:#{job.jid}"] }

    out = Wurk::Api::Serializers.job_record(record)

    assert_equal [['Status', 'queued:abc']], out[:custom_rows]
  end

  def test_job_record_supports_sidekiq_add_pair_rows
    pair_row = Object.new
    def pair_row.add_pair(job) = ['Lock', job['class']]
    Wurk::Web.config.custom_job_info_rows << pair_row

    assert_equal [%w[Lock MyJob]], Wurk::Api::Serializers.job_record(record)[:custom_rows]
  end

  def test_job_record_skips_broken_or_malformed_rows
    rows = [->(_job) { raise 'boom' }, ->(_job) { 'not a pair' }, ->(job) { ['OK', job.jid] }]
    rows.each { |row| Wurk::Web.config.custom_job_info_rows << row }

    assert_equal [%w[OK abc]], Wurk::Api::Serializers.job_record(record)[:custom_rows]
  end

  # A dead/retry entry that reached the set via kill/"kill all"/encryption
  # route-to-dead, or a direct Sidekiq migration, carries no error_class /
  # error_message — only JobRetry#stamp_error sets them. The serializer must
  # emit "" not null, or the SPA's truncate() throws on null.length and white-
  # screens /dead, /search, /retries (issue #272).
  def test_sorted_entry_coerces_absent_error_fields_to_empty_string
    entry = Wurk::SortedEntry.new(nil, 100.0,
                                  { 'class' => 'MyJob', 'args' => [1], 'jid' => 'abc', 'queue' => 'default' })

    out = Wurk::Api::Serializers.sorted_entry(entry)

    assert_equal '', out[:error_class]
    assert_equal '', out[:error_message]
  end

  # Busy page leader badge (#29): the `leader` flag is a plain identity
  # comparison against ProcessSet#leader — passed in so the serializer never
  # issues its own per-row `dear-leader` GET (that would be an N+1 across the
  # process list).
  def test_process_row_marks_leader_by_identity_match
    leader = process_row_fixture('host:1:abc')
    follower = process_row_fixture('host:2:def')

    assert Wurk::Api::Serializers.process_row(leader, leader_identity: 'host:1:abc')[:leader]
    refute Wurk::Api::Serializers.process_row(follower, leader_identity: 'host:1:abc')[:leader]
  end

  def test_process_row_leader_false_when_no_leader_elected
    proc = process_row_fixture('host:1:abc')

    refute Wurk::Api::Serializers.process_row(proc, leader_identity: '')[:leader]
    refute Wurk::Api::Serializers.process_row(proc)[:leader]
  end

  private

  def record
    Wurk::JobRecord.new({ 'class' => 'MyJob', 'args' => [1], 'jid' => 'abc', 'queue' => 'default' })
  end

  def process_row_fixture(identity)
    Wurk::Process.new(
      'identity' => identity, 'hostname' => 'api-host', 'pid' => 1, 'concurrency' => 10,
      'busy' => 0, 'beat' => Time.now.to_f, 'quiet' => 'false', 'labels' => [], 'queues' => []
    )
  end
end
