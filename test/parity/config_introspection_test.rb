# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# free §4.2: `Config#redis_info` parses a real Redis INFO response and
# `Config#to_json` serializes the options.
class ConfigIntrospectionParityTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_redis_info_is_parsed_redis_info
    info = Sidekiq.default_configuration.redis_info
    direct = Sidekiq.redis { |conn| conn.call('INFO') }

    assert_match(/\A\d+\.\d+\.\d+/, info['redis_version'])
    assert_includes direct, "redis_version:#{info['redis_version']}"
  end

  def test_redis_info_carries_only_what_redis_reported
    info = Sidekiq.default_configuration.redis_info

    refute_includes info.keys, 'size'
    refute_includes info.keys, 'available'
  end

  def test_to_json_parses_back_to_the_options
    config = Sidekiq::Config.new
    config[:timeout] = 7

    assert_equal 7, JSON.parse(config.to_json)['timeout']
  end
end
