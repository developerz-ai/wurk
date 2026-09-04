# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Drives Wurk::TransactionAwareClient (Sidekiq::TransactionAwareClient) against
# real Redis. Covers the enqueue-after-commit contract from issue #164 /
# spec §8: jid returned synchronously, the push held until the surrounding
# ActiveRecord transaction commits, dropped on rollback, push_bulk never
# deferred, and graceful immediate-push when ActiveRecord is absent.
#
# A stand-in `::ActiveRecord` (defined per-test, removed in ensure) captures the
# after-commit blocks so we can assert deferral and simulate commit/rollback.
# Safe because each test class runs in its own forked worker and its methods run
# sequentially (parallelize_me! is a no-op hook here).
class TransactionAwareClientTest < Wurk::Test::UnitCase
  parallelize_me!

  JID_PATTERN = /\A[0-9a-f]{24}\z/

  def setup
    super
    @queue            = "taq-#{Process.pid}-#{object_id}"
    @class_name       = "TxnAwareJob@#{Process.pid}-#{object_id}"
    @pool             = Wurk.configuration.redis_pool
    @saved_job_opts   = Wurk.default_job_options.dup
  end

  def teardown
    Wurk.instance_variable_set(:@default_job_options, @saved_job_opts)
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
    end
  ensure
    super
  end

  # --- Sidekiq.transactional_push! opt-in --------------------------------

  def test_transactional_push_sets_client_class_and_returns_true
    assert Wurk.transactional_push!
    assert_same Wurk::TransactionAwareClient, Wurk.default_job_options['client_class']
  end

  def test_sidekiq_alias_resolves_to_wurk_class
    assert_same Wurk::TransactionAwareClient, Sidekiq::TransactionAwareClient
  end

  def test_sidekiq_transactional_push_delegates
    Sidekiq.transactional_push!

    assert_same Wurk::TransactionAwareClient, Wurk.default_job_options['client_class']
  end

  def test_client_class_is_a_transient_attribute
    assert_includes Wurk::JobUtil::TRANSIENT_ATTRIBUTES, 'client_class'
  end

  # --- push deferral / commit / rollback ---------------------------------

  # One story: jid is returned synchronously, the enqueue is deferred, and the
  # deferred push persists that same jid. Splitting would obscure the contract.
  def test_push_returns_jid_synchronously_but_defers_the_enqueue
    client = Wurk::TransactionAwareClient.new

    with_fake_active_record do |pending|
      jid = client.push(item)

      assert_match JID_PATTERN, jid
      assert_equal 1, pending.size, 'push must register exactly one after-commit hook'
      assert_equal 0, queue_len, 'nothing may hit Redis before commit'

      pending.each(&:call) # simulate transaction commit

      assert_equal 1, queue_len
      assert_equal jid, first_queued['jid'], 'the deferred push must persist the pre-allocated jid'
    end
  end

  def test_rollback_drops_the_push
    client = Wurk::TransactionAwareClient.new

    with_fake_active_record do |_pending|
      client.push(item)
      # never invoke the captured hooks → transaction rolled back
    end

    assert_equal 0, queue_len, 'a rolled-back transaction must enqueue nothing'
  end

  def test_push_runs_immediately_when_no_after_commit_hook_available
    client = Wurk::TransactionAwareClient.new

    jid = without_const(:ActiveRecord) { without_const(:AfterCommitEverywhere) { client.push(item) } }

    assert_match JID_PATTERN, jid
    assert_equal 1, queue_len, 'without an after-commit hook the push must go straight through'
  end

  def test_push_routes_through_after_commit_everywhere_when_active_record_absent
    client = Wurk::TransactionAwareClient.new
    pending = []
    ace = Module.new
    ace.define_singleton_method(:after_commit) { |&blk| pending << blk }

    without_const(:ActiveRecord) do
      with_const(:AfterCommitEverywhere, ace) { client.push(item) }
    end

    assert_equal 1, pending.size, 'must fall back to AfterCommitEverywhere.after_commit'
    assert_equal 0, queue_len, 'still deferred until the captured hook runs'
  end

  def test_push_bulk_is_never_deferred
    client = Wurk::TransactionAwareClient.new

    with_fake_active_record do |pending|
      jids = client.push_bulk('class' => @class_name, 'queue' => @queue, 'args' => [[1], [2], [3]])

      assert_equal 3, jids.size
      assert_empty pending, 'push_bulk must not register an after-commit hook'
      assert_equal 3, queue_len, 'bulk pushes go straight to Redis'
    end
  end

  def test_batching_pushes_immediately
    client = Wurk::TransactionAwareClient.new
    bid = "btest-#{Process.pid}-#{object_id}"
    previous = Thread.current[Wurk::Batch::THREAD_KEY]
    Thread.current[Wurk::Batch::THREAD_KEY] = Struct.new(:bid).new(bid) # stand-in active batch

    with_fake_active_record do |pending|
      assert_predicate client, :batching?
      client.push(item)

      assert_empty pending, 'inside a batch the push must not defer'
      assert_equal 1, queue_len
    end
  ensure
    Thread.current[Wurk::Batch::THREAD_KEY] = previous
    @pool.with { |c| c.call('DEL', "b-#{bid}", "b-#{bid}-jids") } if bid
  end

  # --- end-to-end through the worker DSL ---------------------------------

  # End-to-end acceptance: one perform_async, deferred, committed, asserting the
  # full payload shape lands correctly. Cohesive — keep it as one scenario.
  def test_perform_async_defers_when_transactional_push_enabled
    Wurk.transactional_push!
    klass = build_worker
    jid = nil

    with_fake_active_record do |pending|
      jid = klass.perform_async(1, 2)

      assert_match JID_PATTERN, jid
      assert_equal 0, queue_len, 'perform_async must defer under transactional_push!'

      pending.each(&:call)

      assert_equal 1, queue_len
      payload = first_queued

      assert_equal jid, payload['jid']
      assert_equal [1, 2], payload['args']
      refute payload.key?('client_class'), 'client_class must never reach the wire'
    end
  end

  # A class whose sidekiq_options memoized BEFORE the global opt-in must still
  # route through the transactional client — transactional_push! lives in an
  # initializer, but option memoization order shouldn't decide correctness.
  def test_transactional_push_applies_to_classes_defined_before_opt_in
    klass = build_worker # memoizes options here, before the opt-in below
    Wurk.transactional_push!

    with_fake_active_record do |pending|
      klass.perform_async(:x)

      assert_equal 1, pending.size, 'global opt-in must reach pre-defined classes'
      assert_equal 0, queue_len
    end
  end

  def test_per_call_set_client_class_overrides_default
    klass = build_worker # plain Wurk::Client by default

    with_fake_active_record do |pending|
      klass.set(client_class: Wurk::TransactionAwareClient).perform_async(:x)

      assert_equal 1, pending.size, 'set(client_class:) must route through the transactional client'
      assert_equal 0, queue_len
    end
  end

  private

  def item
    { 'class' => @class_name, 'queue' => @queue, 'args' => [1] }
  end

  def queue_len
    @pool.with { |c| c.call('LLEN', "queue:#{@queue}") }.to_i
  end

  def first_queued
    raw = @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, 0) }.first
    raw && JSON.parse(raw)
  end

  def build_worker
    queue = @queue
    Class.new do
      include Wurk::Worker

      sidekiq_options queue: queue
      def perform(*); end
    end
  end

  # Swaps in a minimal ActiveRecord stand-in whose after_all_transactions_commit
  # captures blocks into `pending` instead of running them, so the test controls
  # commit (call them) vs rollback (drop them). The real ActiveRecord — which the
  # engine suites load into this process — is saved and restored, so nothing
  # leaks to other suites sharing the worker.
  def with_fake_active_record
    pending = []
    ar = Module.new
    ar.define_singleton_method(:after_all_transactions_commit) { |&blk| pending << blk }
    with_const(:ActiveRecord, ar) { yield pending }
  end

  # Temporarily binds Object::<name> to value, restoring whatever was there
  # (including nothing) afterward. Never destroys a real constant.
  def with_const(name, value)
    had = Object.const_defined?(name, false)
    previous = Object.const_get(name, false) if had
    Object.send(:remove_const, name) if had
    Object.const_set(name, value)
    yield
  ensure
    Object.send(:remove_const, name) if Object.const_defined?(name, false)
    Object.const_set(name, previous) if had
  end

  # Temporarily unbinds Object::<name>, restoring it afterward.
  def without_const(name)
    had = Object.const_defined?(name, false)
    previous = Object.const_get(name, false) if had
    Object.send(:remove_const, name) if had
    yield
  ensure
    Object.const_set(name, previous) if had && !Object.const_defined?(name, false)
  end
end
