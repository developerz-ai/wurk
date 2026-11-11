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
