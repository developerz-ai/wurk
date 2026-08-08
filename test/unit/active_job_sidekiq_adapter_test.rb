# frozen_string_literal: true

require_relative '../test_helper'
require 'active_job'
require 'wurk/active_job/wrapper'
require 'active_job/queue_adapters/wurk_adapter'
require 'json'

# A migrating app keeps `config.active_job.queue_adapter = :sidekiq` after the
# one-line gem swap (pillar 1). In a wurk-only bundle Rails' built-in
# `:sidekiq` adapter would `require "sidekiq"` and crash boot; Wurk pre-empts
# that autoload with a Wurk-backed `SidekiqAdapter`. This asserts `:sidekiq`
# resolves to that adapter and that it writes the SAME canonical wrapper
# payload as the `:wurk` path — wire-compat is sacred. See issue #97.
#
# Parallel safety: each test routes to a unique queue derived from the pid +
# object_id; scheduled tests filter the global `schedule` zset by class+queue.
class ActiveJobSidekiqAdapterTest < Wurk::Test::UnitCase
  parallelize_me!

  JID_PATTERN = /\A[0-9a-f]{24}\z/
  WRAPPER_CLASS = 'Sidekiq::ActiveJob::Wrapper'

  def setup
    super
    @queue   = "ajsq-#{Process.pid}-#{object_id}"
    @pool    = Wurk.configuration.redis_pool
    @adapter = ActiveJob::QueueAdapters.lookup(:sidekiq).new
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

  # --- registration: :sidekiq must resolve without the real gem ----------

  def test_lookup_sidekiq_resolves_to_wurk_backed_adapter
    adapter = ActiveJob::QueueAdapters.lookup(:sidekiq)

    assert_equal 'ActiveJob::QueueAdapters::SidekiqAdapter', adapter.name
    assert_includes adapter.ancestors, ActiveJob::QueueAdapters::WurkAdapter
  end

  # The wurk-only bundle has no sidekiq gem; resolving `:sidekiq` must not have
  # triggered the built-in autoload's `require "sidekiq"`.
  def test_sidekiq_gem_is_not_loaded
    refute Gem.loaded_specs.key?('sidekiq'), 'real sidekiq gem unexpectedly in bundle'
  end

  def test_job_wrapper_constant_points_to_canonical_wrapper
    assert_same Sidekiq::ActiveJob::Wrapper, ActiveJob::QueueAdapters.lookup(:sidekiq)::JobWrapper
  end

  # --- enqueue: identical canonical wire shape as the :wurk path ----------

  # One test, one canonical shape — splitting the field assertions would
  # obscure the contract ("the LPUSH'd JSON has exactly these fields").
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
    job = make_job
    @adapter.enqueue(job)

    assert_match JID_PATTERN, job.provider_job_id
    assert_equal first_queued['jid'], job.provider_job_id
  end

  # --- enqueue_at: scheduled ---------------------------------------------

  def test_enqueue_at_zadds_to_schedule_with_score
    at = future_seconds(600)
    @adapter.enqueue_at(make_job, at)
    pair = mine_in_schedule.first

    refute_nil pair, 'expected scheduled job in `schedule` zset'
    payload, score = pair

    assert_equal WRAPPER_CLASS, payload['class']
    assert_in_delta at, score.to_f, 0.01
  end

  # --- enqueue_all: immediate + scheduled split --------------------------

  def test_enqueue_all_returns_pushed_count
    assert_equal 2, @adapter.enqueue_all([make_job, make_job])
  end

  def test_enqueue_all_splits_immediate_and_scheduled
    immediate = make_job
    scheduled = make_job.tap { |j| j.scheduled_at = future_time(500) }
    @adapter.enqueue_all([immediate, scheduled])

    assert_equal 1, queued_payloads.size
    assert_equal 1, mine_in_schedule.size
  end

  # --- helpers -----------------------------------------------------------

  private

  def build_job_class(queue)
    klass = Class.new(::ActiveJob::Base) do
      def perform(*); end
    end
    klass.queue_as(queue)
    # Anonymous AJ classes are unusable for serialization. Assign a unique name.
    name = "SidekiqAdapterTestJob_#{Process.pid}_#{object_id}_#{rand(1 << 32)}"
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
