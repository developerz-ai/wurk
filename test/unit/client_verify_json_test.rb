# frozen_string_literal: true

require_relative '../test_helper'
require 'stringio'
require 'logger'

# Pins where and how often Wurk::Client walks a job's args.
#
# `verify_json` recurses the whole args tree and `strict_args_mode` defaults to
# `:raise`, so an extra call is an extra full walk on every enqueue — #push used
# to do it twice. Both paths now match Sidekiq exactly: #push verifies the
# payload the client chain returned (sidekiq client.rb:101), #push_bulk verifies
# inside the innermost block (sidekiq client.rb:165), which is what keeps a
# halting middleware from paying for a walk it is about to discard.
#
# `:warn` mode is the observable proof — the double walk logged the same warning
# twice per push.
#
# Real Redis, per-test queue namespace. Takes GLOBAL_STATE_MUTEX for the whole
# class: the mode matrix flips `Wurk.strict_args_mode`, which JobUtilTest also
# owns.
class ClientVerifyJsonTest < Wurk::Test::UnitCase
  parallelize_me!

  def run(*)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize { super }
  end

  def setup
    super
    @queue      = "cv-q-#{Process.pid}-#{object_id}"
    @class_name = "ClientVerifyJob@#{Process.pid}-#{object_id}"
    @pool       = Wurk.configuration.redis_pool
    @events     = []
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
    end
  ensure
    super
  end

  # --- #push ---------------------------------------------------------------

  def test_push_verifies_exactly_once
    client(RecordingMiddleware).push(item)

    assert_equal 1, @events.count(:verify)
  end

  # Deliberately the mirror image of the #push_bulk order below: #push runs the
  # walk on the payload the chain returned (`invoke_chain` + verify), bulk runs
  # it in the innermost block (`invoke_chain_verified`). Both match Sidekiq.
  def test_push_verifies_after_the_client_middleware_chain
    client(RecordingMiddleware).push(item)

    assert_equal %i[before after verify], @events
  end

  def test_push_skips_verification_when_middleware_halts
    assert_nil client(HaltingMiddleware).push(item)
    assert_equal %i[halt], @events
    assert_equal(0, queue_depth)
  end

  def test_push_raises_on_complex_args_without_enqueueing
    with_strict_mode(:raise) do
      err = assert_raises(ArgumentError) { client(RecordingMiddleware).push(item(args: [:sym])) }

      assert_match(/native JSON/, err.message)
    end

    assert_equal(0, queue_depth)
  end

  def test_push_warns_once_per_complex_arg_and_still_enqueues
    log = with_strict_mode(:warn) { capture_log { client(RecordingMiddleware).push(item(args: [:sym])) } }

    assert_equal 1, log.scan('native JSON').size
    assert_equal(1, queue_depth)
  end

  # --- #push_bulk ----------------------------------------------------------

  def test_push_bulk_verifies_exactly_once_per_job
    client(RecordingMiddleware).push_bulk('class' => @class_name, 'queue' => @queue, 'args' => [[1], [2], [3]])

    assert_equal 3, @events.count(:verify)
  end

  # Inside the chain, unlike #push above — a halting middleware must be able to
  # short-circuit the walk on args it is about to drop.
  def test_push_bulk_verifies_inside_the_client_middleware_chain
    client(RecordingMiddleware).push_bulk('class' => @class_name, 'queue' => @queue, 'args' => [[1]])

    assert_equal %i[before verify after], @events
  end

  def test_push_bulk_skips_verification_when_middleware_halts
    client(HaltingMiddleware).push_bulk('class' => @class_name, 'queue' => @queue, 'args' => [[1]])

    assert_equal %i[halt], @events
    assert_equal(0, queue_depth)
  end

  def test_push_bulk_raises_on_complex_args_without_enqueueing
    with_strict_mode(:raise) do
      assert_raises(ArgumentError) do
        client(RecordingMiddleware).push_bulk('class' => @class_name, 'queue' => @queue, 'args' => [[1], [:sym]])
      end
    end

    assert_equal(0, queue_depth)
  end

  def test_push_bulk_warns_once_per_complex_arg
    log = with_strict_mode(:warn) do
      capture_log do
        client(RecordingMiddleware).push_bulk('class' => @class_name, 'queue' => @queue, 'args' => [[:a], [:b]])
      end
    end

    assert_equal 2, log.scan('native JSON').size
  end

  private

  def client(middleware)
    chain = Wurk::Middleware::Chain.new(Wurk.configuration)
    chain.add(middleware, @events)
    RecordingClient.new(pool: @pool, chain: chain, events: @events)
  end

  def item(args: [1])
    { 'class' => @class_name, 'args' => args, 'queue' => @queue }
  end

  def queue_depth = @pool.with { |conn| conn.call('LLEN', "queue:#{@queue}") }

  def with_strict_mode(mode)
    original = Wurk.strict_args_mode
    Wurk.strict_args!(mode)
    yield
  ensure
    Wurk.strict_args!(original)
  end

  def capture_log
    io    = StringIO.new
    saved = Wurk.configuration.logger
    Wurk.configuration.logger = ::Logger.new(io)
    yield
    io.string
  ensure
    Wurk.configuration.logger = saved
  end

  # Records every args walk. Subclassing beats stubbing here — the override sits
  # exactly where JobUtil's method would, so it counts calls from both paths
  # without caring which one made them.
  class RecordingClient < Wurk::Client
    def initialize(events:, **)
      super(**)
      @events = events
    end

    def verify_json(item)
      @events << :verify
      super
    end
  end

  class RecordingMiddleware
    def initialize(events) = @events = events

    def call(_worker, _job, _queue, _redis)
      @events << :before
      result = yield
      @events << :after
      result
    end
  end

  class HaltingMiddleware
    def initialize(events) = @events = events

    def call(_worker, _job, _queue, _redis)
      @events << :halt
      nil
    end
  end
end
