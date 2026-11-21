# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'
require 'wurk/preflight'

# Sidekiq Pro 7.3 keeps in-flight jobs in `queue:sq|<identity>|<queue>`
# (`Sidekiq::Pro::SuperFetch#private_queue`), with identity
# `<host>:<pid>:<12 hex>`. These drive the real Reaper against real Redis: a
# dead owner's list goes back to its queue, a live owner's is never touched.
class FetcherProPrivateListTest < Wurk::Test::UnitCase
  parallelize_me!

  NONCE = '0123456789ab'
  IDENTITY = "web-1:4242:#{NONCE}".freeze

  def setup
    super
    @ns = "pro-#{Process.pid}-#{SecureRandom.hex(4)}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.default_capsule.queues = ["#{@ns}-served"]
    @pool = @config.default_capsule.redis_pool
    @reaper = Wurk::Fetcher::Reaper.new(@config, interval: 1, lock_key: "#{@ns}:lock", grace: 0)
    @keys = ["#{@ns}:lock"]
    Wurk::Middleware::PoisonPill.reset!
  end

  def teardown
    Wurk::Middleware::PoisonPill.reset!
    @pool.with do |c|
      c.call('DEL', *@keys)
      c.call('SREM', Wurk::Keys::PROCESSES, IDENTITY)
      c.call('SREM', Wurk::Keys::QUEUES_SET, "sq|#{IDENTITY}|#{@ns}")
    end
    @config.reset_redis_pools!
  ensure
    super
  end

  # --- parsing -----------------------------------------------------------

  def test_parses_pros_key_shape
    assert_equal ['queue:default', 'web-1', 4242, NONCE], parse("queue:sq|#{IDENTITY}|default")
  end

  def test_keeps_a_pipe_inside_the_queue_name
    assert_equal ['queue:eu|payments', 'web-1', 4242, NONCE], parse("queue:sq|#{IDENTITY}|eu|payments")
  end

  def test_keeps_an_all_digit_queue_name
    assert_equal ['queue:2024', 'web-1', 4242, NONCE], parse("queue:sq|#{IDENTITY}|2024")
  end

  def test_reads_a_host_holding_colons
    assert_equal ['queue:default', 'fe80::1', 4242, NONCE], parse("queue:sq|fe80::1:4242:#{NONCE}|default")
  end

  # Both readings are well-formed: Pro's queue `2024|1`, or a Wurk pre-nonce
  # list of a queue named `sq` owned by host `<identity>`, pid 2024. Picking one
  # could judge the wrong owner dead, so neither is acted on.
  def test_refuses_a_key_that_reads_as_both_pro_and_wurk
    assert_nil parse("queue:sq|#{IDENTITY}|2024|1")
    assert_nil parse("queue:sq|#{IDENTITY}|eu|7|#{NONCE}|0")
  end

  def test_refuses_malformed_pro_keys
    ['queue:sq|', 'queue:sq||default', "queue:sq|#{IDENTITY}", "queue:sq|#{IDENTITY}|",
     "queue:sq|#{IDENTITY}||x", "queue:sq|#{IDENTITY}|x|", 'queue:sq|web-1:4242|default',
     'queue:sq|web-1:abc:0123456789ab|default', 'queue:sq|web-1:0:0123456789ab|default',
     'queue:sq|web-1:042:0123456789ab|default', 'queue:sq|web-1:4242:0123456789AB|default',
     'queue:sq|web-1:4242:short|default', ":4242:#{NONCE}|default",
     "queue:sq|:4242:#{NONCE}|default"].each do |key|
      assert_nil parse(key), "#{key.inspect} is not a private list"
    end
  end

  def test_refuses_a_key_with_invalid_encoding
    assert_nil parse("queue:sq|web-1:4242:#{NONCE}|\xFF")
  end

  def test_existing_wurk_shapes_still_parse
    assert_equal ['queue:sq', 'host', 123, NONCE], parse("queue:sq|host|123|#{NONCE}|0")
    assert_equal ['queue:sq', 'host', 123, nil], parse('queue:sq|host|123|0')
    assert_equal ['queue:default', 'host', 123, NONCE], parse("queue:default|host|123|#{NONCE}|0")
    assert_equal ['queue:eu|jobs', '123456789012', 4242, nil], parse('queue:eu|jobs|123456789012|4242|0')
  end

  # --- liveness ----------------------------------------------------------

  def test_a_dead_owners_list_goes_back_to_its_queue
    list, public_q = seed("#{@ns}-q")

    assert_equal 2, @reaper.reclaim!
    assert_equal 0, llen(list)
    assert_equal 2, llen(public_q)
  end

  def test_a_dead_owners_list_keeps_the_pipe_in_its_queue
    list, public_q = seed("#{@ns}|payments")

    assert_equal 2, @reaper.reclaim!
    assert_equal 0, llen(list)
    assert_equal 2, llen(public_q)
  end

  def test_a_live_owners_list_is_never_drained
    list, public_q = seed("#{@ns}-q")
    beat

    assert_equal 0, @reaper.reclaim!
    assert_equal 2, llen(list)
    assert_equal 0, llen(public_q)
  end

  # Pro's clean stop leaves `processes` before its hash expires, and the hash
  # is what proves the process is still finishing work.
  def test_a_heartbeat_outside_the_processes_set_still_counts_as_alive
    list, = seed("#{@ns}-q")
    beat(member: false)

    assert_equal 0, @reaper.reclaim!
    assert_equal 2, llen(list)
  end

  def test_a_stale_processes_member_without_a_heartbeat_is_dead
    list, public_q = seed("#{@ns}-q")
    @pool.with { |c| c.call('SADD', Wurk::Keys::PROCESSES, IDENTITY) }

    assert_equal 2, @reaper.reclaim!
    assert_equal 0, llen(list)
    assert_equal 2, llen(public_q)
  end

  def test_the_grace_holds_a_list_whose_heartbeat_just_lapsed
    reaper = Wurk::Fetcher::Reaper.new(@config, interval: 1, lock_key: "#{@ns}:lock", grace: 60)
    list, = seed("#{@ns}-q")

    assert_equal 0, reaper.reclaim!
    assert_equal 2, llen(list)
  end

  def test_an_owner_that_beats_during_the_grace_keeps_its_list
    reaper = Wurk::Fetcher::Reaper.new(@config, interval: 1, lock_key: "#{@ns}:lock", grace: 0.05)
    list, = seed("#{@ns}-q")
    reaper.reclaim!
    beat
    wait_for_grace(reaper)

    assert_equal 0, reaper.drain_settled
    assert_equal 2, llen(list)
  end

  def test_an_ambiguous_key_is_left_alone
    list = "queue:sq|#{IDENTITY}|2024|1"
    @keys.push(list, 'queue:sq')
    @pool.with { |c| c.call('RPUSH', list, job('a')) }

    assert_equal 0, @reaper.reclaim!
    assert_equal 1, llen(list)
  end

  # A public queue may be named anything, including something that reads as a
  # private list. It has no owner to be dead.
  def test_a_public_queue_shaped_like_a_pro_list_is_not_drained
    name = "sq|#{IDENTITY}|#{@ns}"
    list = "queue:#{name}"
    @keys.push(list, "queue:#{@ns}")
    @pool.with do |c|
      c.call('SADD', Wurk::Keys::QUEUES_SET, name)
      c.call('RPUSH', list, job('a'))
    end

    assert_equal 0, @reaper.reclaim!
    assert_equal 1, llen(list)
  end

  def test_preflight_sorts_pro_lists_by_their_owners_heartbeat
    dead = "queue:sq|web-2:7:#{NONCE}|default"
    live = "queue:sq|#{IDENTITY}|default"
    beat

    reader = Struct.new(:pool) do
      def call(*cmd) = pool.with { |c| c.call(*cmd) }
      def pipeline(cmds) = pool.with { |c| c.pipelined { |p| cmds.each { |cmd| p.call(*cmd) } } }
    end.new(@pool)
    verdicts = Wurk::Preflight::Owners.new(reader).classify([dead, live])

    assert_equal [live], verdicts['owner_alive']
    assert_equal [dead], verdicts['reclaimable']
    assert_empty verdicts['unparseable']
  end

  private

  def parse(key) = Wurk::Fetcher::PrivateListKey.parse_full(key)

  def seed(queue)
    list = "queue:sq|#{IDENTITY}|#{queue}"
    public_q = "queue:#{queue}"
    @keys.push(list, public_q)
    @pool.with { |c| c.call('RPUSH', list, job('a'), job('b')) }
    [list, public_q]
  end

  def beat(member: true)
    @keys << IDENTITY
    @pool.with do |c|
      c.call('HSET', IDENTITY, 'info', '{}')
      c.call('SADD', Wurk::Keys::PROCESSES, IDENTITY) if member
    end
  end

  def wait_for_grace(reaper)
    grace = reaper.instance_variable_get(:@grace)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until grace.next_due_in.to_f.zero?
      flunk 'grace never ran out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
  end

  def job(tag)
    JSON.generate('class' => 'ProJob', 'jid' => "#{@ns}-#{tag}", 'args' => [], 'queue' => 'q')
  end

  def llen(key) = @pool.with { |c| c.call('LLEN', key) }
end
