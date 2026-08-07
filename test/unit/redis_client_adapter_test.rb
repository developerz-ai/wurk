# frozen_string_literal: true

require_relative '../test_helper'

# #204: connections yielded by Wurk.redis / Sidekiq.redis answer method-style
# commands (`conn.hgetall`, `conn.smembers`, …) like Sidekiq 7+'s
# RedisClientAdapter::CompatClient — the surface every ecosystem gem uses.
class RedisClientAdapterTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @key = "rca-#{Process.pid}-#{object_id}"
  end

  def teardown
    @pool.with { |c| c.call('DEL', @key) }
    super
  end

  def test_alias_exposes_adapter_and_error_constants
    assert_same Wurk::RedisClientAdapter, Sidekiq::RedisClientAdapter
    assert_same RedisClient::Error, Sidekiq::RedisClientAdapter::BaseError
    assert_same RedisClient::CommandError, Sidekiq::RedisClientAdapter::CommandError
  end

  def test_used_commands_answer_method_style
    @pool.with do |conn|
      conn.set(@key, 'v')

      assert_equal 'v', conn.get(@key)
      assert_equal 1, conn.exists(@key)
    end
  end

  def test_hash_commands_round_trip
    @pool.with do |conn|
      conn.hset(@key, 'a', '1', 'b', '2')

      assert_equal({ 'a' => '1', 'b' => '2' }, conn.hgetall(@key))
      assert_equal %w[1 2], conn.hmget(@key, 'a', 'b')
    end
  end

  def test_call_still_works_through_the_decorator
    @pool.with do |conn|
      assert_equal 'PONG', conn.call('PING')
    end
  end

  def test_unlisted_command_routes_through_method_missing
    @pool.with do |conn|
      assert_equal 'hello', conn.echo('hello')
    end
  end

  def test_deprecated_command_warns_and_still_executes
    @pool.with do |conn|
      assert_output(nil, /deprecated.*hmset/m) { conn.hmset(@key, 'f', 'v') }
      assert_equal 'v', conn.hget(@key, 'f')
    end
  end

  def test_info_returns_parsed_hash
    @pool.with do |conn|
      info = conn.info

      assert_kind_of Hash, info
      assert info.key?('redis_version')
    end
  end

  def test_evalsha_uses_sidekiq_arg_shape
    @pool.with do |conn|
      sha = conn.call('SCRIPT', 'LOAD', 'return redis.call("GET", KEYS[1])')
      conn.set(@key, 'lua')

      assert_equal 'lua', conn.evalsha(sha, [@key], [])
    end
  end

  def test_config_is_delegated
    @pool.with do |conn|
      assert_respond_to conn.config, :host
    end
  end

  # Every hot command in USED_COMMANDS must resolve as a real defined method,
  # not fall through method_missing — respond_to? without include_private
  # reports method_missing's own presence (it's public-ish via
  # respond_to_missing?'s super) the same as any other method, so this checks
  # the *public* instance method table directly instead.
  def test_used_commands_are_eagerly_defined_not_dispatched_via_method_missing
    defined = Wurk::RedisClientAdapter::CompatMethods.instance_methods(false)

    Wurk::RedisClientAdapter::CompatMethods::USED_COMMANDS.each do |name|
      assert_includes defined, name.to_sym, "#{name} must be an eagerly defined method, not method_missing-dispatched"
    end
  end

  # respond_to? alone can't distinguish "really defined" from "answered by
  # respond_to_missing?", so also spy on method_missing itself: a USED_COMMANDS
  # entry must never reach it. Uses a fake `call`-recording host (not real
  # Redis) so this can call every command — including destructive ones like
  # flushdb/unlink/del — without touching the shared per-worker test DB.
  class DispatchSpyHost
    include Wurk::RedisClientAdapter::CompatMethods

    attr_reader :calls, :method_missing_hits

    def initialize
      @calls = []
      @method_missing_hits = []
    end

    def call(*args, **_kwargs, &)
      @calls << args.first
      nil
    end

    def method_missing(*args, &)
      @method_missing_hits << args.first
      super
    rescue NoMethodError
      nil
    end
    ruby2_keywords :method_missing

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  def test_used_commands_never_reach_method_missing
    host = DispatchSpyHost.new

    Wurk::RedisClientAdapter::CompatMethods::USED_COMMANDS.each do |name|
      host.public_send(name)
    end

    assert_equal Wurk::RedisClientAdapter::CompatMethods::USED_COMMANDS, host.calls,
                 'every USED_COMMANDS entry must reach #call directly'
    assert_empty host.method_missing_hits, 'no USED_COMMANDS entry may pass through method_missing'
  end

  def test_blmove_is_eagerly_defined_not_dispatched_via_method_missing
    assert_includes Wurk::RedisClientAdapter::CompatMethods.instance_methods(false), :blmove
  end

  # --- round-trip odometer (RedisPool's replay guard reads this) ---

  def test_round_trips_counts_call_and_pipelined
    @pool.with do |conn|
      before = conn.round_trips
      conn.call('PING')
      conn.pipelined { |pipe| pipe.call('PING') }

      assert_equal before + 2, conn.round_trips, 'a pipeline is one round trip'
    end
  end

  # Method-style commands route through CompatMethods, which would otherwise
  # dispatch straight at the wrapped client and slip past the odometer.
  def test_round_trips_counts_method_style_commands
    @pool.with do |conn|
      before = conn.round_trips
      conn.set(@key, 'v')
      conn.echo('hi')
      conn.info

      assert_equal before + 3, conn.round_trips
    end
  end

  # The odometer only moves for a command that came back clean: a raise means
  # nothing applied — rejected by the server or never sent — which is the state
  # the pool's pre-apply backoff stays available for.
  def test_round_trips_holds_when_a_command_raises
    @pool.with do |conn|
      before = conn.round_trips

      assert_raises(RedisClient::CommandError) { conn.call('NOSUCHCOMMAND') }
      assert_equal before, conn.round_trips
    end
  end

  def test_pipelined_yields_compat_pipeline
    @pool.with do |conn|
      conn.pipelined do |pipe|
        pipe.call('SET', @key, 'p')
        pipe.call('EXPIRE', @key, 60)
      end

      assert_equal 'p', conn.get(@key)
    end
  end
end
