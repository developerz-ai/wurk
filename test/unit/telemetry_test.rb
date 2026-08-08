# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/telemetry'
require 'tmpdir'

# The optional-dependency guard around opentelemetry-api.
#
# Every availability case runs in a subprocess against a fixture `opentelemetry-api.rb`
# on the load path, never against whatever the ambient bundle happens to hold:
# the require is a one-way, process-global side effect, and pinning both answers
# to fixtures keeps the suite honest whether or not a later slice adds the real
# gem to the Gemfile. The "absent" fixture *raises* LoadError rather than being
# missing, so it shadows a real gem too.
class TelemetryTest < Wurk::Test::UnitCase
  parallelize_me!

  LIB = File.expand_path('../../lib', __dir__)

  FIXTURES = {
    # Nothing installed: exactly what `require` does when the gem is absent.
    absent: "raise LoadError, 'cannot load such file -- opentelemetry-api'",
    # The whole surface Wurk::Telemetry::REQUIRED_API asks for.
    present: 'module OpenTelemetry; def self.propagation; end; def self.tracer_provider; end; end',
    # A constant that is not the OTel API — a host-owned OpenTelemetry, or a
    # pre-0.17 release of the gem.
    partial: 'module OpenTelemetry; def self.propagation; end; end'
  }.freeze

  # @param fixture [Symbol] key of FIXTURES to shadow `opentelemetry-api` with
  # @param code [String] runs after `entry` is required; print assertions
  # @param entry [String] what the subprocess requires
  def ruby(fixture, code, entry: 'wurk/telemetry')
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'opentelemetry-api.rb'), FIXTURES.fetch(fixture))
      # unshift here rather than via -I: bundler/setup lands from the inherited
      # RUBYOPT and rewrites $LOAD_PATH, so ordering is only guaranteed for a
      # path pushed from the script body.
      script = "$LOAD_PATH.unshift(#{dir.inspect}); require '#{entry}'; #{code}"
      IO.popen([RbConfig.ruby, '-I', LIB, '-e', script], err: %i[child out], &:read)
    end
  end

  # Code that makes the subprocess print `key=<expr>`. The `#{}` is escaped so
  # it interpolates over there, against the fixture, rather than here.
  def probe(key, expr)
    "print \"#{key}=\#{#{expr}}\""
  end

  def available(fixture)
    ruby(fixture, probe('AVAILABLE', 'Wurk::Telemetry.available?'))
  end

  def enabled(fixture, opt_in)
    ruby(fixture, "Wurk.configuration.telemetry = #{opt_in}; #{probe('ENABLED', 'Wurk::Telemetry.enabled?')}")
  end

  def otel_loaded
    probe('LOADED', '$LOADED_FEATURES.grep(/opentelemetry-api/).any?')
  end

  # --- available? --------------------------------------------------------

  def test_missing_gem_does_not_raise_on_require
    assert_includes available(:absent), 'AVAILABLE=', 'require "wurk/telemetry" blew up without opentelemetry-api'
  end

  def test_not_available_without_the_gem
    assert_includes available(:absent), 'AVAILABLE=false'
  end

  def test_available_with_the_gem
    assert_includes available(:present), 'AVAILABLE=true'
  end

  def test_not_available_when_the_constant_lacks_the_required_api
    assert_includes available(:partial), 'AVAILABLE=false'
  end

  # --- enabled? — both halves of the gate --------------------------------

  def test_not_enabled_without_the_gem_even_when_opted_in
    assert_includes enabled(:absent, true), 'ENABLED=false'
  end

  def test_not_enabled_with_the_gem_when_not_opted_in
    assert_includes enabled(:present, false), 'ENABLED=false'
  end

  def test_enabled_with_the_gem_and_the_opt_in
    assert_includes enabled(:present, true), 'ENABLED=true'
  end

  def test_opting_in_without_the_gem_warns_instead_of_silently_no_opping
    out = enabled(:absent, true)

    assert_includes out, 'opentelemetry-api is not installed'
  end

  def test_opting_in_with_the_gem_does_not_warn
    refute_includes enabled(:present, true), 'opentelemetry-api is not installed'
  end

  # --- the additive invariant -------------------------------------------

  # `require "wurk"` must not drag opentelemetry-api into an app that never
  # asked for tracing — not even one that has the gem installed.
  def test_requiring_wurk_does_not_load_the_otel_api
    assert_includes ruby(:present, otel_loaded), 'LOADED=true',
                    'fixture is unreachable; the assertion below would pass vacuously'
    assert_includes ruby(:present, otel_loaded, entry: 'wurk'), 'LOADED=false'
  end

  # The opt-in is what pulls the API in — so an app that traces still gets it
  # without requiring wurk/telemetry by hand.
  def test_opting_in_loads_the_otel_api
    out = ruby(:present, "Wurk.configuration.telemetry = true; #{otel_loaded}", entry: 'wurk')

    assert_includes out, 'LOADED=true'
  end

  def test_no_sidekiq_telemetry_alias
    refute Sidekiq.const_defined?(:Telemetry, false),
           'upstream Sidekiq has no Telemetry constant; aliasing invents a surface instead of mirroring one'
  end

  # --- the same predicate, in this process -------------------------------
  #
  # The subprocess cases above are the real proof: only they exercise the
  # load-time require. These re-run the predicate here so its branches are
  # attributable to lib/wurk/telemetry.rb in the coverage report, which cannot
  # follow an exec'd child.

  # Safe despite `parallelize_me!`: that is a stub in test/test_helper.rb —
  # minitest-parallel_fork splits by process, and tests inside a worker run
  # sequentially — so no other class can observe the constant mid-flight.
  def with_otel(*methods)
    api = Module.new
    methods.each { |m| api.define_singleton_method(m) { nil } }
    Object.const_set(:OpenTelemetry, api)
    yield
  ensure
    Object.send(:remove_const, :OpenTelemetry)
  end

  def silent_config
    Wurk::Configuration.new.tap { |c| c.logger = ::Logger.new(IO::NULL) }
  end

  def test_available_in_process_with_the_full_api
    with_otel(*Wurk::Telemetry::REQUIRED_API) { assert_predicate Wurk::Telemetry, :available? }
  end

  def test_not_available_in_process_with_a_partial_api
    with_otel(:propagation) { refute_predicate Wurk::Telemetry, :available? }
  end

  def test_enabled_in_process_needs_both_halves
    config = silent_config

    with_otel(*Wurk::Telemetry::REQUIRED_API) do
      refute Wurk::Telemetry.enabled?(config), 'gem present, host silent'
      config.telemetry = true

      assert Wurk::Telemetry.enabled?(config)
    end
  end

  def test_not_enabled_in_process_without_the_api
    config = silent_config
    config.telemetry = true

    refute Wurk::Telemetry.enabled?(config)
  end

  def test_enabled_defaults_to_the_process_configuration
    with_otel(*Wurk::Telemetry::REQUIRED_API) do
      refute_predicate Wurk::Telemetry, :enabled?, 'Wurk.configuration does not opt in by default'
    end
  end
end
