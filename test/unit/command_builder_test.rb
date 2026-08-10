# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::CommandBuilder is a shortcut around redis-client's normalizer, so every
# test here is the same assertion twice: the fast path must produce exactly what
# RedisClient::CommandBuilder would have, and anything it declines must reach
# that builder untouched.
class CommandBuilderTest < Wurk::Test::UnitCase
  parallelize_me!

  def assert_matches_redis_client(args, kwargs = nil)
    expected = RedisClient::CommandBuilder.generate(args.dup, kwargs)

    assert_equal expected, Wurk::CommandBuilder.generate(args, kwargs)
  end

  # --- fast path ---

  def test_all_string_command_matches_redis_client
    assert_matches_redis_client(['LMOVE', 'queue:default', 'queue:default|host|1|n|0', 'RIGHT', 'LEFT'])
  end

  def test_single_string_command_matches_redis_client
    assert_matches_redis_client(['PING'])
  end

  def test_fast_path_returns_a_fresh_array
    args = %w[GET key].freeze
    built = Wurk::CommandBuilder.generate(args)

    refute_same args, built
    refute_predicate built, :frozen?
  end

  def test_fast_path_does_not_mutate_the_caller_array
    args = %w[SET key value]
    Wurk::CommandBuilder.generate(args) << 'EX'

    assert_equal %w[SET key value], args
  end

  # --- which branch fires ---
  #
  # Both branches emit identical output, so these assert the decision itself.
  # The regression they exist for: redis-client splats `**kwargs` before calling
  # the builder, so a `call` with no keywords arrives with an EMPTY HASH, never
  # nil — a `.nil?`-only guard sent every command on the hot path down the slow
  # branch, and every output-equality test above still passed.

  def test_empty_kwargs_is_the_fast_path
    assert Wurk::CommandBuilder.fast?(%w[GET key], {})
  end

  def test_the_real_ack_pipeline_commands_are_all_fast
    priv = 'queue:default|host|1|nonce|0'
    payload = '{"class":"J","args":[],"jid":"abc"}'

    [['LREM', priv, '1', payload],
     ['LMOVE', 'queue:default', priv, 'RIGHT', 'LEFT'],
     ['DEL', 'super_fetch:recovered:abc'],
     ['SADD', 'queues', 'default'],
     ['LPUSH', 'queue:default', payload]].each do |command|
      assert Wurk::CommandBuilder.fast?(command, {}), "#{command.first} must not fall off the fast path"
    end
  end

  def test_nil_kwargs_from_call_v_is_the_fast_path
    assert Wurk::CommandBuilder.fast?(%w[GET key], nil)
  end

  def test_non_string_argument_is_not_fast
    refute Wurk::CommandBuilder.fast?(['LREM', 'key', 1, 'payload'], {})
    refute Wurk::CommandBuilder.fast?(['HSET', 'key', { 'a' => 1 }], {})
    refute Wurk::CommandBuilder.fast?(['GET', :key], {})
  end

  def test_real_kwargs_are_not_fast
    refute Wurk::CommandBuilder.fast?(%w[SET key value], { ex: 60 })
  end

  def test_empty_command_is_not_fast
    refute Wurk::CommandBuilder.fast?([], {})
  end

  # --- declined shapes, which must behave exactly as redis-client does ---

  def test_hash_argument_is_spliced
    assert_matches_redis_client(['HSET', 'key', { 'a' => 1, 'b' => 2 }])
  end

  def test_symbol_and_number_arguments_are_stringified
    assert_matches_redis_client(['LREM', 'key', 1, :value])
  end

  def test_float_argument_is_stringified
    assert_matches_redis_client(['ZADD', 'schedule', 1_786_000_000.5, 'payload'])
  end

  def test_keyword_arguments_are_appended
    assert_matches_redis_client(%w[SET key value], { ex: 60 })
  end

  def test_empty_kwargs_hash_matches_redis_client
    assert_matches_redis_client(%w[GET key], {})
    assert_matches_redis_client(['HSET', 'key', { 'a' => 1 }], {})
  end

  def test_empty_command_raises_like_redis_client
    assert_raises(ArgumentError) { Wurk::CommandBuilder.generate([]) }
  end

  def test_unsupported_argument_type_raises_like_redis_client
    assert_raises(TypeError) { Wurk::CommandBuilder.generate(['GET', Object.new]) }
  end

  # --- wiring ---

  def test_pool_installs_the_builder_by_default
    assert_equal Wurk::CommandBuilder, Wurk::RedisPool::DEFAULT_CLIENT_CONFIG[:command_builder]
  end

  def test_host_supplied_builder_wins
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, command_builder: RedisClient::CommandBuilder)

    assert_equal RedisClient::CommandBuilder, pool.client_config[:command_builder]
  ensure
    pool&.disconnect!
  end

  def test_commands_round_trip_through_a_real_connection
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url)
    key = "cmdbuilder:#{SecureRandom.hex(4)}"

    pool.with do |conn|
      conn.call('HSET', key, { 'a' => 1 })
      conn.call('HSET', key, 'b', '2')

      assert_equal({ 'a' => '1', 'b' => '2' }, conn.call('HGETALL', key))
      conn.call('DEL', key)
    end
  ensure
    pool&.disconnect!
  end
end
