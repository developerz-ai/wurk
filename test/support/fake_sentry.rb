# frozen_string_literal: true

# Stand-in for the sentry-ruby SDK. `sentry-ruby` is a dev-only dependency and
# is never a runtime dep of the gem, so the behavioral tests drive this double
# instead: it records what Wurk::Sentry asked the SDK to do, and asserting on
# the recording pins the contract without a network transport.
#
# `SentryConstantSwap` installs it as the top-level `::Sentry` constant for the
# duration of a test. Safe because minitest-parallel_fork runs each test class
# in its own forked worker, and tests inside a class run sequentially.
#
# The shape is kept honest by SentrySdkSurfaceTest, which asserts the real
# sentry-ruby objects respond to every method used here.
module FakeSentry
  # Mirrors the subset of Sentry::Scope that Wurk::Sentry::JobContext touches.
  # The `set_*` names are Sentry's, not ours.
  class Scope
    attr_reader :transaction_name, :transaction_source, :tags, :contexts, :breadcrumbs_cleared

    def initialize
      @tags = {}
      @contexts = {}
      @breadcrumbs_cleared = false
    end

    def clear_breadcrumbs
      @breadcrumbs_cleared = true
    end

    def set_transaction_name(name, source: nil)
      @transaction_name = name
      @transaction_source = source
    end

    def set_tags(hash) # rubocop:disable Naming/AccessorMethodName
      @tags.merge!(hash)
    end

    def set_context(key, value)
      @contexts[key] = value
    end
  end

  class << self
    attr_accessor :captured, :scopes, :hub_clones
    attr_writer :initialized

    def reset!(initialized: true)
      @initialized = initialized
      @captured = []
      @scopes = []
      @hub_clones = 0
    end

    def initialized?
      @initialized
    end

    def clone_hub_to_current_thread
      @hub_clones += 1
    end

    def with_scope
      scope = Scope.new
      @scopes << scope
      yield scope
    end

    def capture_exception(exception, **options)
      @captured << { exception: exception, options: options }
      nil
    end

    def captured_exceptions
      @captured.map { |entry| entry[:exception] }
    end

    def last_scope
      @scopes.last
    end
  end
end

# setup/teardown pair that installs FakeSentry as `::Sentry`.
module SentryConstantSwap
  def setup
    super
    FakeSentry.reset!
    Object.const_set(:Sentry, FakeSentry)
  end

  def teardown
    if Object.const_defined?(:Sentry) && Object.const_get(:Sentry).equal?(FakeSentry)
      Object.send(:remove_const, :Sentry)
    end
  ensure
    super
  end
end
