# frozen_string_literal: true

require_relative '../test_helper'

# #283: Sidekiq normalizes `config.redis` itself before handing it to
# redis-client, so ordinary Sidekiq initializers carry keys redis-client has
# never known. Wurk splatted the hash straight through and blew up with
# `ArgumentError: unknown keyword: :network_timeout` — inside the forked
# children only, since they're what build the pools.
class RedisOptionsTest < Wurk::Test::UnitCase
  parallelize_me!

  DEFAULTS = Wurk::RedisPool::DEFAULT_CLIENT_CONFIG

  # --- network_timeout / timeout (the reported crash) --------------------

  def test_network_timeout_fans_out_to_the_split_socket_timeouts
    config = normalize(url: 'redis://example:6379/0', network_timeout: 5)

    assert_equal({ connect_timeout: 5, read_timeout: 5, write_timeout: 5 },
                 config.slice(:connect_timeout, :read_timeout, :write_timeout))
    refute config.key?(:network_timeout), 'network_timeout is not a redis-client keyword'
  end

  def test_timeout_fans_out_the_same_way
    config = normalize(timeout: 4)

    assert_equal({ connect_timeout: 4, read_timeout: 4, write_timeout: 4 },
                 config.slice(:connect_timeout, :read_timeout, :write_timeout))
    refute config.key?(:timeout)
  end

  def test_explicit_split_timeouts_win_over_the_umbrella
    config = normalize(network_timeout: 5, read_timeout: 9)

    assert_equal 9, config[:read_timeout], 'an explicit split timeout must beat the fan-out'
    assert_equal 5, config[:connect_timeout]
    assert_equal 5, config[:write_timeout]
  end

  def test_umbrella_absent_leaves_the_wurk_defaults_alone
    config = normalize(url: 'redis://example:6379/0')

    assert_equal DEFAULTS[:connect_timeout], config[:connect_timeout]
    assert_equal DEFAULTS[:read_timeout], config[:read_timeout]
  end

  # --- the rest of the Sidekiq option surface ----------------------------

  def test_full_sidekiq_shaped_hash_normalizes_to_redis_client_keywords
    config = normalize(url: 'redis://example:6379/0', driver: 'hiredis',
                       network_timeout: 5, pool_timeout: 5, size: 12, logger: ::Logger.new(IO::NULL))

    assert_equal(%i[command_builder connect_timeout driver read_timeout reconnect_attempts url write_timeout],
                 config.keys.sort)
    assert_equal :hiredis, config[:driver], 'driver is a symbol in redis-client, a string in most YAML configs'
  end

  def test_pool_and_ignored_keys_never_reach_redis_client
    config = normalize(size: 3, pool_timeout: 2, pool_name: 'x', name: 'y', on_error: -> {},
                       logger: ::Logger.new(IO::NULL), cluster_safe: true)

    assert_empty config.keys - DEFAULTS.keys
  end

  def test_master_name_becomes_the_sentinel_name
    config = normalize(sentinels: [{ host: 'h', port: 26_379 }], master_name: 'mymaster', role: 'replica')

    assert_equal 'mymaster', config[:name]
    assert_equal :replica, config[:role]
    refute config.key?(:master_name)
  end

  def test_sentinel_config_drops_the_default_url
    config = normalize(sentinels: [{ host: 'h', port: 26_379 }], master_name: 'mymaster')

    refute config.key?(:url), 'SentinelConfig derives the master name and db from :url — a default would poison it'
    assert Wurk::RedisOptions.sentinel?(config)
  end

  def test_sentinel_predicate_is_false_for_a_plain_url_config
    refute Wurk::RedisOptions.sentinel?(normalize(url: 'redis://example:6379/0'))
  end

  def test_string_keys_are_accepted
    config = normalize('url' => 'redis://example:6379/0', 'network_timeout' => 7)

    assert_equal 7, config[:read_timeout]
  end

  # --- rejected keys: named, with the replacement -------------------------

  def test_namespace_raises_naming_the_replacement
    error = assert_raises(ArgumentError) { Wurk::RedisOptions.validate!(namespace: 'app') }

    assert_includes error.message, 'config.redis[:namespace]'
    assert_includes error.message, 'own Redis database'
  end

  def test_cluster_nodes_raises_naming_the_replacement
    error = assert_raises(ArgumentError) { Wurk::RedisOptions.validate!(nodes: %w[redis://a redis://b]) }

    assert_includes error.message, 'config.redis[:nodes]'
    assert_includes error.message, 'sentinels:'
  end

  def test_unknown_key_raises_naming_the_key_instead_of_dying_in_a_child
    error = assert_raises(ArgumentError) { Wurk::RedisOptions.validate!(url: 'redis://x', conect_timeout: 1) }

    assert_includes error.message, ':conect_timeout'
    assert_includes error.message, 'connect_timeout', 'the supported-key list is the actionable half of the message'
  end

  def test_unknown_keys_are_all_reported_at_once
    error = assert_raises(ArgumentError) { Wurk::RedisOptions.validate!(bogus: 1, alsobogus: 2) }

    assert_match(/unknown options .*:bogus.*:alsobogus/, error.message)
  end

  def test_known_keys_are_read_off_redis_client_itself
    keys = Wurk::RedisOptions.known_keys

    # Config, Config::Common and SentinelConfig respectively.
    assert_includes keys, :url
    assert_includes keys, :reconnect_attempts
    assert_includes keys, :sentinels
  end

  private

  def normalize(options)
    Wurk::RedisOptions.normalize(options, defaults: DEFAULTS)
  end
end
