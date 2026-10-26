# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Regression coverage for the batch middleware's ordering anchor.
#
# `Wurk::Batch::ServerMiddleware` must stay OUTSIDE of
# `Wurk::Middleware::Expiry` and `Wurk::Limiter::ServerMiddleware`:
#
#   * Expiry SKIPS an expired job by returning without yielding. Inside the
#     batch onion the batch's `ack_success` never runs, the batch's pending
#     never drops and the batch never completes.
#   * The Limiter turns an over-limit job into a `Limiter::Rescheduled` (a
#     JobRetry::Skip). Inside the batch onion the batch's generic
#     `rescue StandardError` books a spurious failure for a job that never ran.
#
# `Chain#add` appends, so re-registering the batch middleware (a
# `configure_server` block, a test helper) used to move it inside both. The
# anchor keeps it outside — this file pins that, and that the batch
# accounting still completes.
#
# Real Redis, never mocked. Every BID + queue is scoped to PID:object_id
# and torn down.
class BatchMiddlewareOrderTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @pool       = Wurk.configuration.redis_pool
    @class_name = "BatchOrderJob@#{Process.pid}-#{object_id}"
    @queue      = "bmoq-#{Process.pid}-#{object_id}"
    @cbq        = "bmocbq-#{Process.pid}-#{object_id}"
    @bids       = []
  end

  def teardown
    @pool.with do |conn|
      @bids.uniq.each do |bid|
        conn.call('UNLINK', *Wurk::Batch.keys_for(bid))
        # Callback dedup markers live outside keys_for (own 30d TTL).
        conn.call('UNLINK', "b-#{bid}-death", "b-#{bid}-success", "b-#{bid}-complete")
        conn.call('ZREM', 'batches', bid)
        conn.call('ZREM', 'dead-batches', bid)
      end
      [@queue, @cbq].each do |q|
        conn.call('DEL', "queue:#{q}")
        conn.call('SREM', 'queues', q)
      end
    end
  ensure
    super
  end

  # --- ordering -----------------------------------------------------------

  # Registering the batch middleware on a chain that already holds Expiry and
  # the Limiter — and registering it a second time — must leave it outside
  # both.
  def test_reregistered_batch_middleware_stays_outer_of_expiry_and_limiter
    entries = build_chain.entries.map(&:klass)
    batch_i = entries.index(Wurk::Batch::ServerMiddleware)
    expiry_i = entries.index(Wurk::Middleware::Expiry)
    limiter_i = entries.index(Wurk::Limiter::ServerMiddleware)

    refute_nil batch_i, 'Batch::ServerMiddleware must be registered'
    refute_nil expiry_i, 'Expiry must be registered'
    refute_nil limiter_i, 'Limiter::ServerMiddleware must be registered'
    assert_operator batch_i, :<, expiry_i, 'Batch must stay OUTER of Expiry'
    assert_operator batch_i, :<, limiter_i, 'Batch must stay OUTER of Limiter::ServerMiddleware'
    assert_equal 1, entries.count(Wurk::Batch::ServerMiddleware),
                 'the re-registration must not duplicate the entry'
  end

  # --- accounting: an expired job still completes the batch ---------------

  # Expiry returns without yielding, so the batch's `ack_success` only runs
  # when the batch middleware is OUTSIDE it. Inside it the pending would never
  # drop and the batch would never complete.
  def test_expired_job_drops_the_batch_pending_and_fires_complete
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }
    jid = jid_for(batch.bid)
    job = { 'class' => @class_name, 'args' => [], 'jid' => jid, 'bid' => batch.bid,
            'queue' => @queue, 'expiry' => ::Time.now.to_f - 60 }

    build_chain.invoke(nil, job, @queue) { flunk 'an expired job must not reach perform' }

    status = Wurk::Batch::Status.new(batch.bid)

    assert_equal 0, status.pending, 'the expired job must still ack success for the batch'
    assert_equal 1, exists("b-#{batch.bid}-complete"), 'the batch must fire :complete'
  end

  # --- accounting: a rate-limited job books neither success nor failure ---

  # The Limiter re-enqueues the job and raises `Limiter::Rescheduled` (a
  # JobRetry::Skip). With the batch middleware OUTSIDE it, the skip is
  # re-raised untouched: no success ack, no failure ack, no :complete. Inside
  # it, the batch's generic `rescue StandardError` would book a failure for a
  # job that never ran.
  def test_over_limited_job_books_neither_success_nor_failure
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }
    jid = jid_for(batch.bid)
    limiter = Wurk::Limiter.bucket("bmo-#{Process.pid}-#{object_id}", 1, :minute,
                                   wait_timeout: 0, reschedule: 5)
    job = { 'class' => @class_name, 'args' => [], 'jid' => jid, 'bid' => batch.bid, 'queue' => @queue }

    assert_raises(Wurk::Limiter::Rescheduled) do
      build_chain.invoke(nil, job, @queue) { raise Wurk::Limiter::OverLimit.new(limiter, job) }
    end

    status = Wurk::Batch::Status.new(batch.bid)

    assert_equal 1, status.pending, 'a rescheduled job must not ack success'
    assert_equal 0, status.failures, 'a rescheduled job must not ack failure'
    assert_equal 0, exists("b-#{batch.bid}-complete"), 'the batch must not fire :complete'
  end

  private

  # A server chain that already holds Expiry and the Limiter, with the batch
  # middleware registered on top of them — and registered a second time, the
  # shape a host's `configure_server` block produces.
  def build_chain
    chain = Wurk::Middleware::Chain.new(Wurk.configuration)
    chain.add(Wurk::Middleware::Expiry)
    chain.add(Wurk::Limiter::ServerMiddleware)
    chain.add(Wurk::Batch::ServerMiddleware)
    chain.add(Wurk::Batch::ServerMiddleware)
    chain
  end

  # Fresh batch scoped to this test's callback queue, with the given
  # event => target callbacks registered.
  def new_batch(**callbacks)
    batch = Wurk::Batch.new
    @bids << batch.bid
    batch.callback_queue = @cbq
    callbacks.each { |event, target| batch.on(event, target) }
    batch
  end

  # Push through Wurk::Client so the batch client middleware stamps the bid
  # and the push routes through BATCH_PUSH.
  def perform_one
    Wurk::Client.push('class' => @class_name, 'args' => [], 'queue' => @queue)
  end

  def jid_for(bid)
    queued(@queue).find { |j| j['bid'] == bid }.fetch('jid')
  end

  def queued(queue)
    @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, -1) }.map { |s| JSON.parse(s) }
  end

  def exists(key)
    @pool.with { |c| c.call('EXISTS', key) }
  end
end
