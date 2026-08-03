# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::Middleware::InterruptHandler against real Redis and the real reliable
# fetcher. MiddlewareBuiltinsTest already pins the wire shape (RPUSH cmd/key/
# payload) against a fake pool; this proves the ordering effect that shape is
# for: F7 regressed when the repush used LPUSH (head of queue) instead of
# RPUSH (tail) — the interrupted job landed *behind* whatever backlog was
# already sitting in the queue instead of being the very next fetch, since
# the fetcher's LMOVE pops from the tail (RIGHT).
#
# Spec: docs/target/sidekiq-free.md §10.3 (IterableJob interrupt/resume).
class InterruptHandlerTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns      = "irqh-#{Process.pid}-#{object_id}"
    @qname   = "irqh-#{@ns}"
    @rqname  = "queue:#{@qname}"
    @config  = Wurk::Configuration.new
    @capsule = Wurk::Capsule.new('test', @config)
    @capsule.queues = [@qname]
    @fetcher = Wurk::Fetcher::Reliable.new(@capsule)
    @pool    = @capsule.redis_pool
    @handler = Wurk::Middleware::InterruptHandler.new
    @handler.config = @capsule
  end

  def teardown
    @pool.with { |c| c.call('DEL', @rqname, private_queue) }
  ensure
    super
  end

  def test_repushed_job_is_fetched_before_older_backlog
    seed_backlog('older-1', 'older-2')
    interrupted_job = { 'class' => 'X', 'jid' => 'irqh-jid-1', 'args' => [] }

    assert_raises(Wurk::JobRetry::Skip) do
      @handler.call(nil, interrupted_job, @qname) { raise Wurk::Job::Interrupted }
    end

    uow = @fetcher.retrieve_work

    refute_nil uow
    assert_equal interrupted_job, ::JSON.parse(uow.job)
  end

  def test_older_backlog_is_still_fetched_after_the_repushed_job
    seed_backlog('older-1')
    interrupted_job = { 'class' => 'X', 'jid' => 'irqh-jid-2', 'args' => [] }

    assert_raises(Wurk::JobRetry::Skip) do
      @handler.call(nil, interrupted_job, @qname) { raise Wurk::Job::Interrupted }
    end

    first  = @fetcher.retrieve_work
    second = @fetcher.retrieve_work

    assert_equal interrupted_job, ::JSON.parse(first.job)
    assert_equal 'older-1', ::JSON.parse(second.job)['args'].first
  end

  # A cooperatively-cancelled job raised while a fresh (non-interrupted)
  # backlog job was LPUSH'd after it must still resume ahead of that fresh
  # enqueue too, not just ahead of pre-existing backlog.
  def test_repushed_job_is_fetched_before_a_fresh_enqueue_made_afterward
    interrupted_job = { 'class' => 'X', 'jid' => 'irqh-jid-3', 'args' => [] }

    assert_raises(Wurk::JobRetry::Skip) do
      @handler.call(nil, interrupted_job, @qname) { raise Wurk::Job::Interrupted }
    end
    seed_backlog('fresh-after-repush')

    uow = @fetcher.retrieve_work

    refute_nil uow
    assert_equal interrupted_job, ::JSON.parse(uow.job)
  end

  private

  def seed_backlog(*payloads)
    @pool.with do |c|
      payloads.each do |p|
        c.call('LPUSH', @rqname, ::Wurk.dump_json({ 'class' => 'Old', 'args' => [p] }))
      end
    end
  end

  def private_queue
    Wurk::Fetcher::Reliable.private_queue_name(@rqname)
  end
end
