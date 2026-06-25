# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/controllers/wurk/api/serializers'

# Custom job-info rows (spec §25.2) flow from the host-registered
# Wurk::Web.config.custom_job_info_rows into the job-record JSON the SPA renders
# in its detail modal. Mutates the global Wurk::Web.config singleton, so this
# class is intentionally not parallelized.
class ApiSerializersTest < Wurk::Test::UnitCase
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

  private

  def record
    Wurk::JobRecord.new({ 'class' => 'MyJob', 'args' => [1], 'jid' => 'abc', 'queue' => 'default' })
  end
end
