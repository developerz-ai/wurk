# frozen_string_literal: true

# The environment every child bench/vs_sidekiq.rb spawns runs under.
#
# Lives in its own file so it can be exercised directly: bench/vs_sidekiq.rb is
# a script, and requiring it runs a multi-minute benchmark, so a test that only
# read its source could not prove the environment it actually builds.
module BenchVsSidekiq
  # Every channel `bundle exec` uses to reach into a subprocess, closed.
  #
  # RUBYOPT carries `-rbundler/setup`; BUNDLER_SETUP is the same hook by another
  # route (rubygems requires it from gem_prelude, so clearing RUBYOPT alone does
  # not stop it); GEM_HOME/GEM_PATH pin the child to the PARENT bundle's gem
  # dir; BUNDLE_LOCKFILE outranks BUNDLE_GEMFILE outright — newer bundlers
  # export it from `set_bundle_variables`, and `default_lockfile` returns it
  # verbatim when set, so the child reads wurk's Gemfile.lock no matter which
  # Gemfile it was pointed at.
  #
  # Any one of them surviving sends the Sidekiq side to wurk's bundle — where
  # stock sidekiq is not installed — and `bundle check`/`install` fail before a
  # single job runs. Clearing all of them is what makes BUNDLE_GEMFILE alone
  # decide which "sidekiq" the child loads, instead of wurk's shadowing
  # lib/sidekiq.rb.
  #
  # test/unit/bench_vs_sidekiq_env_test.rb asks the installed bundler what it
  # injects rather than trusting this list, so a new channel in a future bundler
  # fails there instead of at measurement time.
  module ChildEnv
    LEAKS = %w[
      RUBYOPT
      RUBYLIB
      BUNDLER_SETUP
      BUNDLER_VERSION
      BUNDLE_BIN_PATH
      BUNDLE_LOCKFILE
      GEM_HOME
      GEM_PATH
    ].freeze

    # A nil value in a spawn env hash unsets the variable in the child, rather
    # than passing the parent's through. `extra` merges last: a caller adding
    # its own variables is deliberate, and so is one that names a leak.
    def self.build(gemfile:, redis_url:, shape:, done_key:, extra: {})
      LEAKS.to_h { |key| [key, nil] }.merge(
        'BUNDLE_GEMFILE' => gemfile,
        'REDIS_URL' => redis_url,
        'WURK_BENCH_VS_SHAPE' => shape,
        'WURK_BENCH_VS_DONE_KEY' => done_key
      ).merge(extra)
    end
  end
end
