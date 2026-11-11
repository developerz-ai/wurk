# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# `wurk boot-check` against a real Rails app, in its own process: the way a CI
# step runs it. The worker boot differs from the web and test boots (no engine
# unless something asks for it, a forced eager load, routes drawn), and the
# crash-loops it exists for only ever showed up there.
class BootCheckCliTest < Wurk::Test::UnitCase
  ROOT = File.expand_path('../..', __dir__)
  DUMMY = File.join(ROOT, 'test', 'dummy')
  WURK = File.join(ROOT, 'exe', 'wurk')

  def test_the_dummy_app_passes
    out, status = boot_check(DUMMY, 'REDIS_URL' => 'redis://127.0.0.1:1/0')

    assert_predicate status, :success?, out
    assert_match(/wurk: boot-check \(as wurkswarm parent\); \d+ process/, out)
    assert_match(/AR pool \d+/, out)
    assert_match(/booted as wurkswarm would/, out)
  end

  # The CSP-initializer crash-loop: an initializer that names a constant only the
  # web process has loaded.
  def test_an_app_whose_initializer_needs_an_engine_constant_fails_naming_it
    with_dummy_copy("Wurk::ApplicationController\n") do |app|
      out, status = boot_check(app, 'REDIS_URL' => 'redis://127.0.0.1:1/0')

      refute_predicate status, :success?
      assert_match(/^wurk: uninitialized constant Wurk::ApplicationController$/, out)
      assert_match(%r{config/initializers/broken\.rb}, out)
    end
  end

  def test_with_redis_it_writes_nothing
    Wurk.redis { |c| c.call('SET', 'boot-check:sentinel', '1') }
    before = keyspace

    out, status = boot_check(DUMMY, { 'REDIS_URL' => Wurk::Test.redis_url }, '--redis')

    assert_predicate status, :success?, out
    # The banner names the server: redis, valkey or dragonfly on the compat legs.
    assert_match(/Wurk #{Regexp.escape(Wurk::VERSION)} on (?:redis|valkey|dragonfly) /, out)
    assert_equal before, keyspace
  end

  # The production adopter's shape: a server-only initializer that writes Redis
  # (theirs flushed the DB). A boot-check must not be able to run it against a
  # real server, with or without --redis.
  WRITES_REDIS = <<~RUBY
    Wurk.configure_server do
      Wurk.redis { |conn| conn.call('SET', 'boot-check:written', '1') }
    end
  RUBY

  def test_an_initializer_that_writes_redis_fails_without_reaching_it
    with_dummy_copy(WRITES_REDIS) do |app|
      out, status = boot_check(app, 'REDIS_URL' => Wurk::Test.redis_url)

      refute_predicate status, :success?, out
      assert_match(%r{^wurk: wurk boot-check: \S*config/initializers/broken\.rb:2 opened a Redis connection}, out)
      assert_nil(Wurk.redis { |c| c.call('GET', 'boot-check:written') })
    end
  end

  def test_with_redis_an_initializer_may_read_but_not_write
    with_dummy_copy(WRITES_REDIS) do |app|
      out, status = boot_check(app, { 'REDIS_URL' => Wurk::Test.redis_url }, '--redis')

      refute_predicate status, :success?, out
      assert_match(%r{config/initializers/broken\.rb:2 sent SET while the app booted}, out)
      assert_nil(Wurk.redis { |c| c.call('GET', 'boot-check:written') })
    end
  end

  def test_the_single_process_runner_boots_as_wurk_does
    out, status = boot_check(DUMMY, { 'REDIS_URL' => 'redis://127.0.0.1:1/0' }, '--runner', 'wurk')

    assert_predicate status, :success?, out
    assert_match(/wurk: boot-check \(as wurk\); 1 process × \d+ threads/, out)
    assert_match(/booted as wurk would/, out)
    refute_match(/wurkswarm|Wurk swarm/, out)
  end

  def test_the_swarm_runner_does_not_claim_to_fork
    out, status = boot_check(DUMMY, 'REDIS_URL' => 'redis://127.0.0.1:1/0')

    assert_predicate status, :success?, out
    refute_match(/forking/, out)
  end

  private

  def boot_check(app, env, *flags)
    env = { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile'), 'COVERAGE' => nil, 'RAILS_ENV' => nil }.merge(env)
    out, status = Open3.capture2e(env, RbConfig.ruby, WURK, 'boot-check', '-r', app, '-e', 'test', *flags,
                                  chdir: ROOT)
    [out, status]
  end

  def with_dummy_copy(initializer)
    Dir.mktmpdir('wurk-boot-check') do |dir|
      app = File.join(dir, 'app')
      FileUtils.cp_r(DUMMY, app)
      File.write(File.join(app, 'config', 'initializers', 'broken.rb'), initializer)
      yield app
    end
  end

  def keyspace
    Wurk.redis { |c| c.call('KEYS', '*').sort.to_h { |key| [key, c.call('DUMP', key)] } }
  end
end
