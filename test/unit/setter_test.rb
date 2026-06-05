# frozen_string_literal: true

require_relative '../test_helper'

class SetterTest < Wurk::Test::UnitCase
  parallelize_me!

  # Worker that records perform_inline invocations and lets tests stub
  # `client_push` / `build_client` to capture would-be enqueues.
  class SpyWorker
    include Wurk::Worker

    sidekiq_options queue: 'spec', retry: 7

    @inline_calls = []
    class << self
      attr_reader :inline_calls
      attr_accessor :captured_item, :captured_bulk

      def client_push(item)
        @captured_item = item
        'pushed-jid'
      end

      def build_client
        client = Object.new
        captured = self
        client.define_singleton_method(:push_bulk) do |hash|
          captured.captured_bulk = hash
          %w[jid-a jid-b]
        end
        client
      end
    end

    def perform(*args)
      self.class.inline_calls << args
    end
  end

  def setup
    super
    SpyWorker.captured_item = nil
    SpyWorker.captured_bulk = nil
    SpyWorker.inline_calls.clear
  end

  # --- construction & set merge --------------------------------------

  def test_initialize_stringifies_keys
    setter = Wurk::Worker::Setter.new(SpyWorker, queue: 'urgent', retry: 3)
    setter.perform_async

    assert_equal 'urgent', SpyWorker.captured_item['queue']
    assert_equal 3, SpyWorker.captured_item['retry']
  end

  def test_set_returns_self_for_chaining
    setter = SpyWorker.set(queue: 'a')

    assert_same setter, setter.set(retry: 1)
  end

  # Drop-in: code that does `set(...).is_a?(Sidekiq::Job::Setter)` must work.
  # The constant resolves through the modern `Sidekiq::Job` namespace. Issue #96.
  def test_set_result_is_a_sidekiq_job_setter
    assert_kind_of Sidekiq::Job::Setter, SpyWorker.set(queue: 'x')
  end

  def test_set_merges_subsequent_options
    SpyWorker.set(queue: 'a').set(retry: 9).perform_async('x')

    assert_equal 'a', SpyWorker.captured_item['queue']
    assert_equal 9, SpyWorker.captured_item['retry']
  end

  # --- wait / wait_until → at ----------------------------------------

  def test_wait_until_converts_time_to_at
    target = Time.now + 600
    Wurk::Worker::Setter.new(SpyWorker, wait_until: target).perform_async

    assert_in_delta target.to_f, SpyWorker.captured_item['at'], 0.01
  end

  def test_wait_converts_numeric_to_future_at
    before = Time.now.to_f
    Wurk::Worker::Setter.new(SpyWorker, wait: 30).perform_async

    assert_operator SpyWorker.captured_item['at'], :>=, before + 29.9
    assert_operator SpyWorker.captured_item['at'], :<=, Time.now.to_f + 0.5 + 30
  end

  # --- perform_async --------------------------------------------------

  def test_perform_async_builds_class_args_payload
    SpyWorker.set(queue: 'high').perform_async(1, 'two', { 'k' => 'v' })

    item = SpyWorker.captured_item

    assert_equal SpyWorker, item['class']
    assert_equal [1, 'two', { 'k' => 'v' }], item['args']
    assert_equal 'high', item['queue']
  end

  def test_perform_async_returns_jid_from_client_push
    assert_equal 'pushed-jid', SpyWorker.set(queue: 'q').perform_async
  end

  # --- sync mode ------------------------------------------------------

  def test_sync_true_routes_perform_async_through_perform_inline
    SpyWorker.set(sync: true).perform_async('inline-arg')

    assert_equal [['inline-arg']], SpyWorker.inline_calls
    assert_nil SpyWorker.captured_item
  end

  def test_perform_inline_runs_perform_directly
    Wurk::Worker::Setter.new(SpyWorker, {}).perform_inline('p')

    assert_equal [['p']], SpyWorker.inline_calls
  end

  def test_perform_sync_is_alias_of_perform_inline
    Wurk::Worker::Setter.new(SpyWorker, {}).perform_sync('s')

    assert_equal [['s']], SpyWorker.inline_calls
  end

  # --- perform_in / perform_at ---------------------------------------

  def test_perform_in_relative_seconds_sets_future_at
    before = Time.now.to_f
    SpyWorker.set(queue: 'q').perform_in(60, 'x')

    assert_operator SpyWorker.captured_item['at'], :>=, before + 59.9
    assert_operator SpyWorker.captured_item['at'], :<, before + 70
  end

  def test_perform_at_absolute_timestamp_preserved
    future = Time.now.to_f + 86_400 # well above 1e9 threshold
    Wurk::Worker::Setter.new(SpyWorker, {}).perform_at(future, 'y')

    assert_in_delta future, SpyWorker.captured_item['at'], 0.5
  end

  def test_perform_in_below_threshold_treated_as_relative
    # 999_999_999 < 1e9, treated as relative — would push 31+ years out
    setter = Wurk::Worker::Setter.new(SpyWorker, {})
    setter.perform_in(Wurk::Worker::SCHEDULED_THRESHOLD - 1, 'z')

    assert_operator SpyWorker.captured_item['at'], :>, Time.now.to_f + Wurk::Worker::SCHEDULED_THRESHOLD - 2
  end

  def test_perform_in_past_relative_skips_at
    # -1 second is in the past once added to now → no at field
    Wurk::Worker::Setter.new(SpyWorker, {}).perform_in(-1, 'q')

    refute SpyWorker.captured_item.key?('at')
  end

  def test_perform_in_past_absolute_skips_at
    Wurk::Worker::Setter.new(SpyWorker, {}).perform_at(Time.now.to_f - 60, 'q')

    refute SpyWorker.captured_item.key?('at')
  end

  def test_perform_at_alias_of_perform_in
    assert_equal Wurk::Worker::Setter.instance_method(:perform_in),
                 Wurk::Worker::Setter.instance_method(:perform_at)
  end

  def test_perform_in_rejects_garbage_interval
    assert_raises(ArgumentError) do
      Wurk::Worker::Setter.new(SpyWorker, {}).perform_in('soon')
    end
  end

  # --- perform_bulk ---------------------------------------------------

  def test_perform_bulk_constructs_single_payload_with_args_array
    SpyWorker.set(queue: 'bulk').perform_bulk([[1], [2], [3]])

    bulk = SpyWorker.captured_bulk

    assert_equal SpyWorker, bulk['class']
    assert_equal [[1], [2], [3]], bulk['args']
    assert_equal 'bulk', bulk['queue']
  end

  def test_perform_bulk_merges_extra_opts
    SpyWorker.set(queue: 'bulk').perform_bulk([[1]], batch_size: 50, at: 123.0)
    bulk = SpyWorker.captured_bulk

    assert_equal 50, bulk['batch_size']
    assert_in_delta(123.0, bulk['at'])
  end

  def test_perform_bulk_returns_array_of_jids
    result = SpyWorker.set(queue: 'bulk').perform_bulk([[1], [2]])

    assert_equal %w[jid-a jid-b], result
  end
end
