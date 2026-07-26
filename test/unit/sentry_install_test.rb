# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/fake_sentry'
require 'wurk/sentry'

# Wurk::Sentry.install! — the one call a consumer makes, plus the guard that
# keeps the whole integration inert when sentry-ruby is absent.
class SentryInstallTest < Wurk::Test::UnitCase
  parallelize_me!

  def config
    @config ||= begin
      cfg = Wurk::Configuration.new
      cfg.logger = Logger.new(IO::NULL)
      cfg
    end
  end

  def sentry_handlers(cfg = config)
    cfg.error_handlers.grep(Wurk::Sentry::ErrorHandler)
  end

  # =====================================================================
  # install!
  # =====================================================================

  def test_registers_the_server_middleware
    Wurk::Sentry.install!(config)

    assert config.server_middleware.exists?(Wurk::Sentry::Middleware)
  end

  def test_registers_one_error_handler
    Wurk::Sentry.install!(config)

    assert_equal 1, sentry_handlers.size
  end

  def test_keeps_the_default_logging_handler
    Wurk::Sentry.install!(config)

    assert_includes config.error_handlers, Wurk::Configuration::ERROR_HANDLER
  end

  def test_returns_the_config
    assert_same config, Wurk::Sentry.install!(config)
  end

  def test_defaults_to_the_global_configuration
    Wurk::Sentry.install!

    assert Wurk.configuration.server_middleware.exists?(Wurk::Sentry::Middleware)
  ensure
    Wurk.configuration.server_middleware.remove(Wurk::Sentry::Middleware)
    Wurk.configuration.error_handlers.reject! { |h| h.is_a?(Wurk::Sentry::ErrorHandler) }
  end

  # =====================================================================
  # Idempotency
  # =====================================================================

  def test_repeated_install_registers_the_middleware_once
    3.times { Wurk::Sentry.install!(config) }
    entries = config.server_middleware.entries.map(&:klass)

    assert_equal 1, entries.count(Wurk::Sentry::Middleware)
  end

  def test_repeated_install_registers_the_error_handler_once
    3.times { Wurk::Sentry.install!(config) }

    assert_equal 1, sentry_handlers.size
  end

  def test_repeated_install_applies_the_latest_options
    Wurk::Sentry.install!(config)
    Wurk::Sentry.install!(config, filter_transport_errors: false)

    refute sentry_handlers.first.filtered?(RedisClient::ConnectionError.new('reset'))
  end

  def test_install_passes_the_filter_list_through
    Wurk::Sentry.install!(config, filtered_error_classes: [ArgumentError])

    assert_equal [ArgumentError], sentry_handlers.first.filtered_error_classes
  end

  # =====================================================================
  # enabled?
  # =====================================================================

  def test_disabled_when_sentry_ruby_is_absent
    refute_predicate Wurk::Sentry, :enabled?
  end

  def test_disabled_when_a_foreign_sentry_constant_exists
    # A `Sentry` constant that isn't the SDK must not be mistaken for one.
    Object.const_set(:Sentry, Module.new)

    refute_predicate Wurk::Sentry, :enabled?
  ensure
    Object.send(:remove_const, :Sentry)
  end

  def test_disabled_before_sentry_init_runs
    FakeSentry.reset!(initialized: false)
    Object.const_set(:Sentry, FakeSentry)

    refute_predicate Wurk::Sentry, :enabled?
  ensure
    Object.send(:remove_const, :Sentry)
  end

  def test_enabled_once_sentry_is_initialized
    FakeSentry.reset!
    Object.const_set(:Sentry, FakeSentry)

    assert_predicate Wurk::Sentry, :enabled?
  ensure
    Object.send(:remove_const, :Sentry)
  end

  # =====================================================================
  # Opt-in
  # =====================================================================

  def test_requiring_the_file_installs_nothing
    refute Wurk.configuration.server_middleware.exists?(Wurk::Sentry::Middleware),
           'require "wurk/sentry" must not register anything on its own'
  end
end
