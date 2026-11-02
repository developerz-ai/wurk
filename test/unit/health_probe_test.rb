# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/health_probe'

class HealthProbeTest < Wurk::Test::UnitCase
  parallelize_me!

  HOST = 'probe-host'

  def setup
    super
    @out = StringIO.new
    @config = Wurk::Configuration.new
    @config.redis = { url: Wurk::Test.redis_url }
    @config.logger = ::Logger.new(IO::NULL)
    @redis = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @redis&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def probe(config: @config, **) = Wurk::HealthProbe.new(config, hostname: HOST, out: @out, **)

  def test_passes_on_a_fresh_local_heartbeat
    beat("#{HOST}:1:n", ::Time.now.to_f)

    assert_equal 0, probe.call
    assert_match(/1 process/, @out.string)
  end

  def test_fails_when_no_process_on_this_host_exists
    beat('other:1:n', ::Time.now.to_f)

    assert_equal 1, probe.call
  end

  def test_fails_on_a_stale_heartbeat
    beat("#{HOST}:1:n", ::Time.now.to_f - 120)

    assert_equal 1, probe.call
    assert_equal 0, probe(window: 300).call
  end

  def test_min_requires_that_many_fresh_processes
    beat("#{HOST}:1:n", ::Time.now.to_f)

    assert_equal 1, probe(min: 2).call
  end

  def test_redis_it_cannot_reach_passes_unless_strict
    closed = closed_port_config

    assert_equal 0, probe(config: closed).call
    assert_equal 1, probe(config: closed, strict: true).call
  ensure
    closed&.reset_redis_pools!
  end

  def test_cli_routes_health_without_booting_anything
    cli = Wurk::CLI.instance.class.allocate
    cli.send(:initialize)
    cli.config = @config
    cli.parse(['health', '--window', '5', '--min', '2', '--strict', '--redis-url', Wurk::Test.redis_url])

    assert_equal 'health', cli.command
    assert_equal 1, cli.run_health
  end

  def test_help_lists_health_but_not_the_hidden_api_command
    cli = Wurk::CLI.instance.class.allocate
    cli.send(:initialize)
    help = cli.send(:option_parser, {}).help

    assert_match(/^\s+health\s/, help)
    refute_match(/^\s+api\s/, help)
  end

  # A kubelet gives a probe a few seconds. Riding the pool's retries took 4s on a
  # refused connection and 19s on a hung server, so an outage killed every pod.
  def test_refused_redis_answers_well_under_a_second
    closed = closed_port_config

    assert_operator seconds_taken { assert_equal 0, probe(config: closed).call }, :<, 0.5
  end

  def test_hung_redis_answers_within_two_seconds
    hung = TCPServer.new('127.0.0.1', 0)
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config.redis = { url: "redis://127.0.0.1:#{hung.addr[1]}/0", read_timeout: 30, network_timeout: 30 }

    assert_operator seconds_taken { assert_equal 0, probe(config: config).call }, :<, 2.0
  ensure
    hung&.close
  end

  private

  def seconds_taken
    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    yield
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started
  end

  def beat(identity, at)
    @redis.call('SADD', Wurk::Keys::PROCESSES, identity)
    @redis.call('HSET', identity, 'beat', at.to_s)
  end

  def closed_port_config
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    Wurk::Configuration.new.tap do |c|
      c.logger = ::Logger.new(IO::NULL)
      c.redis = { url: "redis://127.0.0.1:#{port}/0" }
    end
  end
end
