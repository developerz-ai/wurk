# frozen_string_literal: true

require_relative '../test_helper'
require 'active_job'
require 'wurk/active_job/wrapper'
require 'active_job/queue_adapters/wurk_adapter'
require 'json'

# Wires ActiveJob into Wurk via the Sidekiq-compatible wrapper. Asserts the
# canonical wire shape (`class = "Sidekiq::ActiveJob::Wrapper"`, `wrapped =
# <user class>`, `args = [job_data]`) so mixed Sidekiq/Wurk worker pools can
# read the same payloads. Wire-compat is sacred.
#
# Parallel safety: each test routes to a unique queue derived from
# `@wurk_test_namespace`. Scheduled tests filter the global `schedule` zset
# by class+queue so concurrent suites can't see each other's pushes.
class ActiveJobAdapterTest < Wurk::Test::UnitCase
  parallelize_me!

  JID_PATTERN = /\A[0-9a-f]{24}\z/
  WRAPPER_CLASS = 'Sidekiq::ActiveJob::Wrapper'

  def setup
    super
    @queue = "ajq-#{Process.pid}-#{object_id}"
    @pool  = Wurk.configuration.redis_pool
    @adapter = ActiveJob::QueueAdapters::WurkAdapter.new
    @job_class = build_job_class(@queue)
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue) if @queue
      cleanup_schedule(conn)
    end
  ensure
    super
  end

  # --- registration -------------------------------------------------------

  def test_lookup_resolves_wurk_symbol_to_adapter
    assert_same ActiveJob::QueueAdapters::WurkAdapter, ActiveJob::QueueAdapters.lookup(:wurk)
  end

  # --- enqueue: shape & wire-compat --------------------------------------

  # rubocop:disable Minitest/MultipleAssertions
  # One test, one canonical shape — splitting the four field assertions
  # would obscure the contract ("the LPUSH'd JSON has exactly these fields").
  def test_enqueue_lpushes_canonical_wrapper_payload
    job = @job_class.new(1, 'two')
    job.queue_name = @queue
    @adapter.enqueue(job)
    payload = first_queued

    assert_equal WRAPPER_CLASS, payload['class']
    assert_equal @job_class.name, payload['wrapped']
    assert_equal @queue, payload['queue']
    assert_match JID_PATTERN, payload['jid']
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_enqueue_wraps_args_as_single_aj_data_hash
    job = @job_class.new('x')
    job.queue_name = @queue
    @adapter.enqueue(job)

    assert_equal 1, first_queued['args'].size
    aj_data = first_queued['args'].first

    assert_equal @job_class.name, aj_data['job_class']
    assert_equal ['x'], aj_data['arguments']
  end

  def test_enqueue_sets_provider_job_id_to_pushed_jid
    job = @job_class.new
    job.queue_name = @queue
    @adapter.enqueue(job)

    assert_match JID_PATTERN, job.provider_job_id
    assert_equal first_queued['jid'], job.provider_job_id
  end

  # --- enqueue_at: scheduled --------------------------------------------

  def test_enqueue_at_zadds_to_schedule_with_score
    at = future_seconds(600)
    job = @job_class.new
    job.queue_name = @queue
    @adapter.enqueue_at(job, at)
    pair = mine_in_schedule.first

    refute_nil pair, 'expected scheduled job in `schedule` zset'
    payload, score = pair

    assert_equal WRAPPER_CLASS, payload['class']
    assert_in_delta at, score.to_f, 0.01
  end

  def test_enqueue_at_does_not_lpush_immediate
    @adapter.enqueue_at(make_job, future_seconds(600))

    assert_empty queued_payloads
  end

  # --- enqueue_all: bulk -------------------------------------------------

  def test_enqueue_all_returns_pushed_count
    jobs = [make_job, make_job]

    assert_equal 2, @adapter.enqueue_all(jobs)
  end

  def test_enqueue_all_lpushes_each_immediate_job
    @adapter.enqueue_all([make_job, make_job])

    assert_equal 2, queued_payloads.size
  end

  def test_enqueue_all_routes_scheduled_jobs_to_schedule_zset
    at = future_time(500)
    jobs = Array.new(2) do
      j = make_job
      j.scheduled_at = at
      j
    end
    @adapter.enqueue_all(jobs)

    assert_equal 2, mine_in_schedule.size
  end

  def test_enqueue_all_splits_immediate_and_scheduled
    immediate = make_job
    scheduled = make_job.tap { |j| j.scheduled_at = future_time(500) }
    @adapter.enqueue_all([immediate, scheduled])

    assert_equal 1, queued_payloads.size
    assert_equal 1, mine_in_schedule.size
  end

  # --- stopping? / lifecycle --------------------------------------------

  def test_stopping_predicate_defaults_false
    refute_predicate ActiveJob::QueueAdapters::WurkAdapter.new, :stopping?
  end

  def test_enqueue_after_transaction_commit_true
    assert_predicate ActiveJob::QueueAdapters::WurkAdapter.new, :enqueue_after_transaction_commit?
  end

  # --- Sidekiq alias surface --------------------------------------------

  def test_wrapper_aliased_under_sidekiq_namespace
    assert_same Sidekiq::ActiveJob::Wrapper, Wurk::ActiveJob::Wrapper
  end

  def test_wrapper_class_to_s_is_sidekiq_namespace
    assert_equal WRAPPER_CLASS, Sidekiq::ActiveJob::Wrapper.to_s
  end

  def test_legacy_job_wrapper_alias_points_to_wrapper
    assert_same Sidekiq::ActiveJob::Wrapper, ActiveJob::QueueAdapters::WurkAdapter::JobWrapper
  end

  def test_options_mixin_present_on_active_job_base
    assert_respond_to ::ActiveJob::Base, :sidekiq_options
  end

  # --- helpers -----------------------------------------------------------

  private

  def build_job_class(queue)
    klass = Class.new(::ActiveJob::Base) do
      def perform(*); end
    end
    klass.queue_as(queue)
    # Anonymous AJ classes are unusable for serialization. Assign a unique name.
    name = "AdapterTestJob_#{Process.pid}_#{object_id}_#{rand(1 << 32)}"
    Object.const_set(name, klass)
    @aj_const_name = name
    klass
  end

  def make_job(args = [])
    job = @job_class.new(*args)
    job.queue_name = @queue
    job
  end

  def first_queued
    queued_payloads.first
  end

  def queued_payloads
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |s| JSON.parse(s) }
  end

  def mine_in_schedule
    @pool.with { |c| c.call('ZRANGE', 'schedule', 0, -1, 'WITHSCORES') }.filter_map do |member, score|
      payload = JSON.parse(member)
      [payload, score] if payload['class'] == WRAPPER_CLASS && payload['queue'] == @queue
    rescue JSON::ParserError
      next
    end
  end

  def cleanup_schedule(conn)
    Object.send(:remove_const, @aj_const_name) if @aj_const_name && Object.const_defined?(@aj_const_name)
    conn.call('ZRANGE', 'schedule', 0, -1).each do |member|
      payload = JSON.parse(member)
      conn.call('ZREM', 'schedule', member) if payload['queue'] == @queue
    rescue JSON::ParserError
      next
    end
  end

  def future_seconds(delta)
    Process.clock_gettime(Process::CLOCK_REALTIME) + delta
  end

  def future_time(delta)
    Time.at(future_seconds(delta))
  end
end
