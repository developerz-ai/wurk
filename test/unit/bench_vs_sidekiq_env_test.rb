# frozen_string_literal: true

require_relative '../test_helper'
require 'English'

# The one control bench/vs_sidekiq.rb has: the Sidekiq side must resolve from
# bench/vs_sidekiq/Gemfile and nothing else. Wurk ships lib/sidekiq.rb, so a
# child that falls back to the repo bundle boots wurk under the name "sidekiq".
#
# `bundle exec` reaches into subprocesses through more channels than RUBYOPT:
# BUNDLER_SETUP is required straight from rubygems' gem_prelude (so clearing
# RUBYOPT alone does not stop it) and GEM_HOME/GEM_PATH pin the child to the
# PARENT bundle's gem dir. Bundler 2.7 exports all of them. Any one surviving
# into the harness's children aims the Sidekiq side at wurk's bundle, where
# stock sidekiq is not installed, and `rake bench:vs_sidekiq` dies in
# install_sidekiq_bundle before a single job runs.
#
# This test asks bundler itself what it injects rather than hard-coding a list,
# so a new channel in a future bundler fails here instead of at measurement time.
class BenchVsSidekiqEnvTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)

  # Set by the harness on purpose — it is the one variable that decides which
  # bundle the child resolves, which is the entire point of clearing the rest.
  DELIBERATE = %w[BUNDLE_GEMFILE].freeze

  # Bundler's record of the pre-exec environment. Inert: nothing reads them to
  # resolve gems, they exist so Bundler.with_original_env can restore the shell.
  ORIGINALS = /\ABUNDLER_ORIG_/

  # Everything that can steer gem resolution in a child.
  RESOLUTION_VARS = /\A(BUNDLE|BUNDLER|GEM_|RUBYOPT|RUBYLIB)/

  def test_child_env_clears_every_variable_bundle_exec_injects
    injected = bundler_injected_vars

    refute_empty injected, '`bundle exec` injected nothing — the probe is broken, not the harness'
    assert_includes injected, 'BUNDLER_SETUP', 'the probe missed the gem_prelude hook this test exists for'

    leaked = injected - bundler_leaks - DELIBERATE

    assert_empty leaked,
                 "bench/vs_sidekiq.rb's child_env leaves #{leaked.join(', ')} pointing at the repo bundle — " \
                 'the Sidekiq side would resolve against wurk, not stock sidekiq'
  end

  private

  # bench/vs_sidekiq.rb is a script, not a library: requiring it runs a
  # multi-minute benchmark. Read the declaration instead, which pins its shape
  # as well as its contents.
  def bundler_leaks
    source = File.read(File.join(ROOT, 'bench', 'vs_sidekiq.rb'))
    literal = source[/^BUNDLER_LEAKS = %w\[(?<names>[^\]]*)\]\.freeze$/, 1]

    refute_nil literal, 'bench/vs_sidekiq.rb no longer declares BUNDLER_LEAKS as a frozen %w[] literal'
    literal.split
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
