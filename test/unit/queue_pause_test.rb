# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::Queue pause/unpause + fetcher filter against real Redis.
# Membership of the `paused` SET is the single source of truth: Queue
# methods read/write it, and the reliable fetcher skips any queue whose
# unprefixed name is a member.
#
# Spec: docs/target/sidekiq-pro.md §6 (Queue pause/resume).
class QueuePauseTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns       = "#{Process.pid}-#{object_id}"
    @qname    = "qpause-#{@ns}"
    @other    = "qpause-other-#{@ns}"
    @rqname   = "queue:#{@qname}"
    @rotherq  = "queue:#{@other}"
    @pool     = Wurk.configuration.redis_pool
    clean_keys
  end

  def teardown
    clean_keys
  ensure
    super
  end

  # --- pause! / unpause! / paused? ----------------------------------

  def test_paused_predicate_false_when_set_empty
    refute_predicate Wurk::Queue.new(@qname), :paused?
  end

  def test_pause_adds_name_to_paused_set
    Wurk::Queue.new(@qname).pause!

    assert_includes paused_members, @qname
  end

  def test_pause_flips_paused_predicate
    q = Wurk::Queue.new(@qname)
    q.pause!

    assert_predicate q, :paused?
  end

  def test_pause_returns_true
    assert(Wurk::Queue.new(@qname).pause!)
  end

  def test_pause_is_idempotent
    q = Wurk::Queue.new(@qname)
    q.pause!
    q.pause!

    assert_equal 1, paused_members.count(@qname)
  end

  def test_unpause_removes_name_from_paused_set
    q = Wurk::Queue.new(@qname)
    q.pause!
    q.unpause!

    refute_includes paused_members, @qname
  end

  def test_unpause_flips_paused_predicate
    q = Wurk::Queue.new(@qname)
    q.pause!
    q.unpause!

    refute_predicate q, :paused?
  end

  def test_unpause_returns_true
    assert(Wurk::Queue.new(@qname).unpause!)
  end

  def test_unpause_is_idempotent_when_not_paused
    assert(Wurk::Queue.new(@qname).unpause!)
    refute_predicate Wurk::Queue.new(@qname), :paused?
  end

  def test_pause_only_affects_named_queue
    Wurk::Queue.new(@qname).pause!

    refute_predicate Wurk::Queue.new(@other), :paused?
  end

  # --- fetcher integration -------------------------------------------

  def test_fetcher_queues_cmd_excludes_paused_queue
    fetcher, capsule = build_fetcher(%W[#{@qname} #{@other}])
    Wurk::Queue.new(@qname).pause!

    refute_includes fetcher.queues_cmd, @rqname
    assert_includes fetcher.queues_cmd, @rotherq
  ensure
    capsule&.stop
  end

  def test_fetcher_queues_cmd_returns_empty_when_all_paused
    fetcher, capsule = build_fetcher(%W[#{@qname} #{@other}])
    Wurk::Queue.new(@qname).pause!
    Wurk::Queue.new(@other).pause!

    assert_empty fetcher.queues_cmd
  ensure
    capsule&.stop
  end

  def test_fetcher_skips_paused_queue_on_retrieve_work
    fetcher, capsule = build_fetcher(%W[#{@qname} #{@other}])
    @pool.with do |c|
      c.call('LPUSH', @rqname, 'paused-payload')
      c.call('LPUSH', @rotherq, 'live-payload')
    end
    Wurk::Queue.new(@qname).pause!

    uow = fetcher.retrieve_work

    refute_nil uow
    assert_equal @rotherq, uow.queue
    assert_equal 'live-payload', uow.job
  ensure
    capsule&.stop
  end

  def test_fetcher_resumes_paused_queue_after_unpause
    fetcher, capsule = build_fetcher(%W[#{@qname}])
    @pool.with { |c| c.call('LPUSH', @rqname, 'job-1') }
    q = Wurk::Queue.new(@qname)
    q.pause!

    assert_empty fetcher.queues_cmd

    q.unpause!

    assert_includes fetcher.queues_cmd, @rqname
  ensure
    capsule&.stop
  end

  private

  def build_fetcher(queues)
    config  = Wurk::Configuration.new
    capsule = Wurk::Capsule.new('test', config)
    capsule.queues = queues
    [Wurk::Fetcher::Reliable.new(capsule), capsule]
  end

  def paused_members
    @pool.with { |c| c.call('SMEMBERS', Wurk::Keys::PAUSED_SET) }
  end

  def clean_keys
    @pool.with do |c|
      c.call('SREM', Wurk::Keys::PAUSED_SET, @qname, @other)
      c.call('DEL', @rqname, @rotherq)
      private_q = Wurk::Fetcher::Reliable.private_queue_name(@rqname)
      private_other = Wurk::Fetcher::Reliable.private_queue_name(@rotherq)
      c.call('DEL', private_q, private_other)
    end
  end
end
