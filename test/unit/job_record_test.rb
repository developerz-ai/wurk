# frozen_string_literal: true

require_relative '../test_helper'
require 'base64'
require 'zlib'
require 'securerandom'

# Drives Wurk::JobRecord shape (parsing, ActiveJob unwrap, error backtrace
# decode) and the one Redis interaction (LREM via #delete).
class JobRecordTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns      = "#{Process.pid}-#{object_id}"
    @qname   = "jr-q-#{@ns}"
    @rqname  = "queue:#{@qname}"
    @pool    = Wurk.configuration.redis_pool
    @pool.with { |c| c.call('DEL', @rqname) }
  end

  def teardown
    @pool.with do |c|
      c.call('DEL', @rqname)
      c.call('SREM', 'queues', @qname)
    end
  ensure
    super
  end

  # --- construction / lazy parse -----------------------------------------

  def test_constructs_from_json_string
    json = Wurk.dump_json(base_item)
    record = Wurk::JobRecord.new(json, @qname)

    assert_equal 'MyJob', record.klass
    assert_equal json, record.value
  end

  def test_constructs_from_hash
    record = Wurk::JobRecord.new(base_item, @qname)

    assert_equal 'MyJob', record.klass
    refute_nil record.value
  end

  def test_queue_falls_back_to_item_queue
    record = Wurk::JobRecord.new(base_item)

    assert_equal @qname, record.queue
  end

  def test_value_is_lazy_from_hash
    record = Wurk::JobRecord.new(base_item, @qname)

    assert_equal base_item['jid'], Wurk.load_json(record.value)['jid']
  end

  # --- field accessors ---------------------------------------------------

  def test_jid_args_klass_proxy_to_item
    record = Wurk::JobRecord.new(base_item, @qname)

    assert_equal 'jid-123', record.jid
    assert_equal [1, 2], record.args
    assert_equal 'MyJob', record.klass
  end

  def test_bid_returns_item_bid
    record = Wurk::JobRecord.new(base_item.merge('bid' => 'BID1'), @qname)

    assert_equal 'BID1', record.bid
  end

  def test_tags_returns_empty_array_when_missing
    assert_empty Wurk::JobRecord.new(base_item, @qname).tags
  end

  def test_tags_returns_item_tags
    record = Wurk::JobRecord.new(base_item.merge('tags' => %w[a b]), @qname)

    assert_equal %w[a b], record.tags
  end

  def test_bracket_reader_proxies_to_item
    record = Wurk::JobRecord.new(base_item.merge('retry' => 5), @qname)

    assert_equal 5, record['retry']
  end

  # --- time accessors ----------------------------------------------------

  def test_enqueued_at_returns_time_from_ms
    ms = ms_now
    record = Wurk::JobRecord.new(base_item.merge('enqueued_at' => ms), @qname)

    assert_kind_of Time, record.enqueued_at
    assert_in_delta ms / 1000.0, record.enqueued_at.to_f, 0.1
  end

  def test_enqueued_at_handles_legacy_float
    secs = ms_now / 1000.0
    record = Wurk::JobRecord.new(base_item.merge('enqueued_at' => secs), @qname)

    assert_in_delta secs, record.enqueued_at.to_f, 0.1
  end

  def test_created_at_returns_nil_when_missing
    item = base_item
    item.delete('created_at')

    assert_nil Wurk::JobRecord.new(item, @qname).created_at
  end

  def test_failed_at_retried_at_return_time_when_set
    failed = ms_now - 1000
    retried = ms_now - 500
    record = Wurk::JobRecord.new(base_item.merge('failed_at' => failed, 'retried_at' => retried), @qname)

    assert_kind_of Time, record.failed_at
    assert_kind_of Time, record.retried_at
  end

  # --- latency -----------------------------------------------------------

  def test_latency_uses_enqueued_at_ms
    record = Wurk::JobRecord.new(base_item.merge('enqueued_at' => ms_now - 6_000), @qname)

    assert_in_delta 6.0, record.latency, 1.5
  end

  def test_latency_class_method_returns_zero_for_nil
    assert_in_delta(0.0, Wurk::JobRecord.latency_from(nil))
  end

  def test_latency_class_method_clamps_negative
    future_ms = ms_now + 10_000

    assert_in_delta(0.0, Wurk::JobRecord.latency_from(future_ms))
  end

  # Legacy float-seconds enqueued_at (< 10^10) hits the `* 1_000` then-branch
  # of latency_from's ms/secs discriminator.
  def test_latency_class_method_handles_legacy_float_seconds
    now_ms = 1_700_000_000_000
    enqueued_secs = (now_ms / 1_000.0) - 5.0

    assert_in_delta(5.0, Wurk::JobRecord.latency_from(enqueued_secs, now_ms), 0.001)
  end

  # --- error backtrace ---------------------------------------------------

  def test_error_backtrace_nil_when_missing
    assert_nil Wurk::JobRecord.new(base_item, @qname).error_backtrace
  end

  def test_error_backtrace_decodes_base64_zlib
    bt = ['lib/foo.rb:1', 'lib/bar.rb:42']
    compressed = Base64.encode64(Zlib.deflate(Wurk.dump_json(bt)))
    record = Wurk::JobRecord.new(base_item.merge('error_backtrace' => compressed), @qname)

    assert_equal bt, record.error_backtrace
  end

  def test_error_backtrace_returns_nil_on_malformed
    record = Wurk::JobRecord.new(base_item.merge('error_backtrace' => 'not-base64-zlib'), @qname)

    assert_nil record.error_backtrace
  end

  # --- display_class / display_args (ActiveJob unwrap) -------------------

  def test_display_class_returns_klass_for_plain_jobs
    record = Wurk::JobRecord.new(base_item, @qname)

    assert_equal 'MyJob', record.display_class
  end

  def test_display_args_returns_args_for_plain_jobs
    record = Wurk::JobRecord.new(base_item, @qname)

    assert_equal [1, 2], record.display_args
  end

  # Second call hits the `defined?` memoization guard (display_class line 94
  # then-branch): same object returned without recomputing.
  def test_display_class_memoizes_on_second_call
    record = Wurk::JobRecord.new(base_item, @qname)
    first = record.display_class

    assert_same first, record.display_class
  end

  # Second call hits the `defined?` memoization guard (display_args line 100
  # then-branch).
  def test_display_args_memoizes_on_second_call
    record = Wurk::JobRecord.new(base_item, @qname)
    first = record.display_args

    assert_same first, record.display_args
  end

  # §4.7: an encryption envelope as the last arg renders as "<encrypted>" so
  # ciphertext never reaches the dashboard. Keyed on envelope shape, so it
  # fires even when the stored hash lacks the `encrypt` flag (as here).
  def test_display_args_masks_encrypted_envelope_last_arg
    item = base_item.merge('args' => [7, encryption_envelope])
    record = Wurk::JobRecord.new(item, @qname)

    assert_equal [7, '<encrypted>'], record.display_args
  end

  # Cleartext preceding args stay visible for triage; only the envelope hides.
  def test_display_args_keeps_cleartext_preceding_encrypted_arg
    item = base_item.merge('args' => ['user-42', 'order-7', encryption_envelope])
    record = Wurk::JobRecord.new(item, @qname)

    assert_equal ['user-42', 'order-7', '<encrypted>'], record.display_args
  end

  # display_class memoization must survive a nil unwrap result so the second
  # call short-circuits even when the value is falsy-ish (here: plain klass).
  def test_display_class_memoizes_active_job_wrapper
    record = Wurk::JobRecord.new(active_job_payload, @qname)
    first = record.display_class

    assert_same first, record.display_class
  end

  # AJ wrapper payload with neither `wrapped` nor args[0]['job_class'] →
  # unwrap_class falls back to klass (line 125 then-branch).
  def test_display_class_falls_back_to_klass_when_no_wrapped_or_job_class
    payload = {
      'class' => 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper',
      'queue' => @qname,
      'jid' => 'aj-jid-2',
      'args' => [{ 'foo' => 'bar' }],
      'created_at' => ms_now,
      'enqueued_at' => ms_now
    }
    record = Wurk::JobRecord.new(payload, @qname)

    assert_equal 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper', record.display_class
  end

  # Mailer wrapper whose arguments have fewer than 2 entries → mailer_display
  # returns nil (line 134 then-branch); unwrap_class falls back to job_class.
  def test_display_class_mailer_with_too_few_args_falls_back_to_job_class
    payload = active_job_payload(
      'wrapped' => 'ActionMailer::MailDeliveryJob',
      'args' => [{ 'job_class' => 'ActionMailer::MailDeliveryJob',
                   'arguments' => ['UserMailer'] }]
    )
    record = Wurk::JobRecord.new(payload, @qname)

    assert_equal 'ActionMailer::MailDeliveryJob', record.display_class
  end

  def test_display_class_unwraps_active_job_wrapper
    record = Wurk::JobRecord.new(active_job_payload, @qname)

    assert_equal 'MyAJob', record.display_class
  end

  def test_display_args_unwraps_active_job_arguments
    record = Wurk::JobRecord.new(active_job_payload, @qname)

    assert_equal %w[hello world], record.display_args
  end

  def test_display_class_unwraps_mailer_delivery
    payload = active_job_payload(
      'wrapped' => 'ActionMailer::MailDeliveryJob',
      'args' => [{ 'job_class' => 'ActionMailer::MailDeliveryJob',
                   'arguments' => ['UserMailer', 'welcome', 'deliver_now', { 'args' => [1] }] }]
    )
    record = Wurk::JobRecord.new(payload, @qname)

    assert_equal 'UserMailer#welcome', record.display_class
  end

  def test_display_args_drops_mailer_envelope
    payload = active_job_payload(
      'wrapped' => 'ActionMailer::MailDeliveryJob',
      'args' => [{ 'job_class' => 'ActionMailer::MailDeliveryJob',
                   'arguments' => ['UserMailer', 'welcome', 'deliver_now', 1, 2] }]
    )
    record = Wurk::JobRecord.new(payload, @qname)

    assert_equal [1, 2], record.display_args
  end

  # --- delete (LREM) -----------------------------------------------------

  def test_delete_removes_exact_payload_and_returns_true
    json = Wurk.dump_json(base_item)
    @pool.with { |c| c.call('LPUSH', @rqname, json) }
    record = Wurk::JobRecord.new(json, @qname)

    assert record.delete
    assert_equal(0, @pool.with { |c| c.call('LLEN', @rqname) })
  end

  def test_delete_returns_false_when_no_match
    record = Wurk::JobRecord.new(base_item, @qname)

    refute record.delete
  end

  private

  def base_item
    {
      'class' => 'MyJob',
      'args' => [1, 2],
      'queue' => @qname,
      'jid' => 'jid-123',
      'created_at' => ms_now,
      'enqueued_at' => ms_now
    }
  end

  def active_job_payload(extra = {})
    {
      'class' => 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper',
      'wrapped' => 'MyAJob',
      'queue' => @qname,
      'jid' => 'aj-jid-1',
      'args' => [{ 'job_class' => 'MyAJob', 'arguments' => %w[hello world] }],
      'created_at' => ms_now,
      'enqueued_at' => ms_now
    }.merge(extra)
  end

  def ms_now
    ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
  end

  # A crypto envelope shaped like Wurk::Encryption.encrypt's output.
  def encryption_envelope
    {
      ::Wurk::Encryption::ENVELOPE_MARKER => true,
      'v' => 1,
      'iv' => 'aXY=',
      'ct' => 'Y3Q=',
      'tag' => 'dGFn'
    }
  end
end
