# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'stringio'

# G3 under Rails: every Rails process says once whether it runs jobs, and why
# not when it does not. The boot policy itself is railtie_test.rb's.
class RailsBootRoleLineTest < Wurk::Test::EngineCase
  class UniqueWithoutUniqueJob
    include Wurk::Job

    sidekiq_options unique_for: 60
  end

  def setup
    super
    @out = StringIO.new
    @original_logger = Wurk.configuration.logger
    Wurk.configuration.logger = ::Logger.new(@out, level: ::Logger::DEBUG)
  end

  def teardown
    Wurk.configuration.logger = @original_logger
    Wurk.worker_boot_claimed = false
  ensure
    super
  end

  def test_a_process_that_runs_no_jobs_says_why
    with_env('WURK_DISABLED' => nil) { Wurk::RailsBoot.boot }

    assert_match(/wurk: client only \(test environment\); this process enqueues and runs no jobs/, @out.string)
  end

  def test_the_client_only_line_stays_off_stdout_at_the_default_level
    Wurk.configuration.logger = ::Logger.new(@out, level: ::Logger::INFO)
    Wurk::RailsBoot.boot

    assert_empty @out.string
  end

  def test_the_first_reason_is_the_one_given
    with_env('WURK_DISABLED' => '1') { Wurk::RailsBoot.boot }

    assert_match(/client only \(WURK_DISABLED=1\)/, @out.string)
  end

  # The runner already announced this process; a second line would contradict it.
  def test_a_process_the_runner_owns_gets_no_line_from_the_railtie
    Wurk.worker_boot_claimed = true
    Wurk::RailsBoot.boot

    assert_empty @out.string
  end

  def test_the_embedded_boot_names_its_server_and_size
    instance = Object.new
    instance.define_singleton_method(:run) { nil }
    klass = Object.new
    klass.define_singleton_method(:new) { |_config| instance }
    Wurk::RailsBoot.define_singleton_method(:at_exit) { |&_blk| nil }

    with_env('WURK_EMBED' => '1') { with_unique_off { Wurk::RailsBoot.boot_embedded(klass) } }

    assert_match(/wurk: embedded in this process \(WURK_EMBED=1\), threads only; 1 process × \d+ threads/,
                 @out.string)
    assert_match(/UniqueWithoutUniqueJob/, @out.string, 'the app checks run on the railtie boot too')
  ensure
    Wurk::RailsBoot.singleton_class.send(:remove_method, :at_exit)
  end

  private

  def with_unique_off
    was = Wurk::Unique.enabled?
    Wurk::Unique.disable!
    yield
  ensure
    Wurk::Unique.instance_variable_set(:@enabled, was)
  end

  def with_env(pairs)
    originals = pairs.to_h { |k, _| [k, ENV.fetch(k, nil)] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
