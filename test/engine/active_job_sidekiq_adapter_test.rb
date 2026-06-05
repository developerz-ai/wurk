# frozen_string_literal: true

require_relative '../engine_test_helper'

# End-to-end drop-in proof for issue #97: inside the booted dummy Rails app, an
# ActiveJob whose `queue_adapter = :sidekiq` (the config a migrating app keeps
# after the one-line gem swap) must enqueue through Wurk and write the canonical
# wrapper payload — and the dashboard's JobRecord must unwrap that wrapper back
# to the user's job class. The booting of the dummy itself proves `:sidekiq`
# resolved without the built-in adapter's `require "sidekiq"` crashing boot.
#
# Parallel safety: a per-test queue + uniquely-named job class; the adapter is
# set on that class only, never on the global ActiveJob::Base.
class ActiveJobSidekiqAdapterEngineTest < Wurk::Test::EngineCase
  parallelize_me!

  WRAPPER_CLASS = 'Sidekiq::ActiveJob::Wrapper'

  def setup
    super
    @queue = "ajse-#{::Process.pid}-#{object_id}"
    @pool  = ::Wurk.configuration.redis_pool
    @job_class = build_job_class(@queue)
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
    end
    Object.send(:remove_const, @aj_const_name) if @aj_const_name && Object.const_defined?(@aj_const_name)
  ensure
    super
  end

  def test_sidekiq_adapter_resolves_in_booted_app
    assert_includes(
      ActiveJob::QueueAdapters.lookup(:sidekiq).ancestors,
      ActiveJob::QueueAdapters::WurkAdapter
    )
  end

  # rubocop:disable Minitest/MultipleAssertions
  # One test, one canonical shape — splitting the field assertions would
  # obscure the contract ("the LPUSH'd JSON has exactly these fields").
  def test_perform_later_enqueues_canonical_wrapper_payload
    @job_class.perform_later('hello')
    payload = first_queued

    refute_nil payload, 'expected the :sidekiq adapter to LPUSH a job'
    assert_equal WRAPPER_CLASS, payload['class']
    assert_equal @job_class.name, payload['wrapped']
    assert_equal @queue, payload['queue']
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_job_record_unwraps_wrapper_to_user_class
    @job_class.perform_later(42)
    record = ::Wurk::JobRecord.new(first_queued, @queue)

    assert_equal @job_class.name, record.display_class
    assert_equal [42], record.display_args
  end

  private

  def build_job_class(queue)
    klass = Class.new(::ActiveJob::Base) do
      def perform(*); end
    end
    klass.queue_as(queue)
    klass.queue_adapter = :sidekiq
    name = "SidekiqEngineJob_#{::Process.pid}_#{object_id}_#{rand(1 << 32)}"
    Object.const_set(name, klass)
    @aj_const_name = name
    klass
  end

  def first_queued
    raw = @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.first
    raw && JSON.parse(raw)
  end
end
