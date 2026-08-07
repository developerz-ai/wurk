# frozen_string_literal: true

require_relative '../test_helper'
require 'English'
require_relative '../../bench/vs_sidekiq/child_env'

# The one control bench/vs_sidekiq.rb has: the Sidekiq side must resolve from
# bench/vs_sidekiq/Gemfile and nothing else. Wurk ships lib/sidekiq.rb, so a
# child that falls back to the repo bundle boots wurk under the name "sidekiq".
#
# `bundle exec` reaches into subprocesses through more channels than RUBYOPT:
# BUNDLER_SETUP is required straight from rubygems' gem_prelude (so clearing
# RUBYOPT alone does not stop it), GEM_HOME/GEM_PATH pin the child to the
# PARENT bundle's gem dir, and BUNDLE_LOCKFILE aims it at the parent's
# lockfile. Bundler exports all of them. Any one surviving into the harness's
# children aims the Sidekiq side at wurk's bundle, where stock sidekiq is not
# installed, and `rake bench:vs_sidekiq` dies in install_sidekiq_bundle before
# a single job runs.
#
# Two halves, both needed: the list must cover what the installed bundler
# actually injects (asked of bundler, not hard-coded, so a new channel in a
# future bundler fails here instead of at measurement time), and the builder
# must actually unset everything on that list.
class BenchVsSidekiqEnvTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  SIDEKIQ_GEMFILE = File.join(ROOT, 'bench', 'vs_sidekiq', 'Gemfile')

  # Set by the harness on purpose — it is the one variable that decides which
  # bundle the child resolves, which is the entire point of clearing the rest.
  DELIBERATE = %w[BUNDLE_GEMFILE].freeze

  # Bundler's record of the pre-exec environment. Inert: nothing reads them to
  # resolve gems, they exist so Bundler.with_original_env can restore the shell.
  ORIGINALS = /\ABUNDLER_ORIG_/

  # Everything that can steer gem resolution in a child.
  RESOLUTION_VARS = /\A(BUNDLE|BUNDLER|GEM_|RUBYOPT|RUBYLIB)/

  def test_child_env_covers_every_variable_bundle_exec_injects
    injected = bundler_injected_vars

    refute_empty injected, '`bundle exec` injected nothing — the probe is broken, not the harness'
    assert_includes injected, 'BUNDLER_SETUP', 'the probe missed the gem_prelude hook this test exists for'

    leaked = injected - BenchVsSidekiq::ChildEnv::LEAKS - DELIBERATE

    assert_empty leaked,
                 "bench/vs_sidekiq.rb's child_env leaves #{leaked.join(', ')} pointing at the repo bundle — " \
                 'the Sidekiq side would resolve against wurk, not stock sidekiq'
  end

  def test_child_env_unsets_every_leak_it_declares
    env = child_env

    BenchVsSidekiq::ChildEnv::LEAKS.each do |name|
      assert env.key?(name), "child_env never mentions #{name}, so the child inherits the parent's value"
      assert_nil env[name], "child_env passes #{name} through instead of unsetting it in the child"
    end
  end

  def test_child_env_pins_the_bundle_it_is_handed
    env = child_env(gemfile: SIDEKIQ_GEMFILE)

    assert_equal SIDEKIQ_GEMFILE, env['BUNDLE_GEMFILE'],
                 'BUNDLE_GEMFILE is what decides which "sidekiq" the child loads'
  end

  # Nothing may point at the repo bundle by any other name: the only
  # resolution-steering variable left with a value is the one we chose.
  def test_child_env_sets_no_resolution_variable_other_than_the_gemfile
    set = child_env.compact.keys.grep(RESOLUTION_VARS)

    assert_equal DELIBERATE, set
  end

  # WURK_COUNT and friends ride along without disturbing the isolation.
  def test_child_env_keeps_extras_and_the_isolation_together
    env = child_env(extra: { 'WURK_COUNT' => '4' })

    assert_equal '4', env['WURK_COUNT']
    assert_nil env['GEM_HOME']
  end

  private

  def child_env(gemfile: SIDEKIQ_GEMFILE, extra: {})
    BenchVsSidekiq::ChildEnv.build(
      gemfile: gemfile, redis_url: 'redis://localhost:6379/12', shape: 'noop',
      done_key: 'wurk-bench:vs:done', extra: extra
    )
  end

  # What `bundle exec` actually puts in a child's environment, asked of the
  # installed bundler rather than assumed.
  def bundler_injected_vars
    script = 'puts ENV.keys'
    out = IO.popen({}, ['bundle', 'exec', RbConfig.ruby, '-e', script], chdir: ROOT, err: %i[child out], &:read)

    assert_equal 0, $CHILD_STATUS.exitstatus, "`bundle exec` failed:\n#{out}"
    out.lines.map(&:strip).grep(RESOLUTION_VARS).grep_v(ORIGINALS)
  end
end
