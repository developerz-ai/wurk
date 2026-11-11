# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/preflight'
require 'fileutils'
require 'tmpdir'

# `wurk preflight --app` rows read off an app checkout: one fixture per row.
class PreflightAppScanTest < Wurk::Test::UnitCase
  parallelize_me!

  Spec = Struct.new(:name, :version, :dependencies)
  ECOSYSTEM = File.expand_path('../ecosystem', __dir__)

  def setup
    super
    @root = Dir.mktmpdir('wurk-app-scan')
    @report = Wurk::Preflight::Report.new('preflight')
  end

  def teardown
    FileUtils.rm_rf(@root)
  ensure
    super
  end

  def test_a_clean_app_has_no_rows
    write('app/jobs/ok_job.rb', "class OkJob; def perform(job) = job['jid']; end\n")
    write('Gemfile.lock', "GEM\n  specs:\n    connection_pool (3.0.2)\n")

    scan

    assert_empty @report.findings
  end

  def test_time_fields_read_off_a_job_are_listed_with_file_and_line
    write('app/services/snapshot.rb', "x = 1\nTime.at(job['failed_at'])\nrow[:created_at]\n")
    write('lib/monitor.rb', "Time.at(msg[\"enqueued_at\"])\n")

    scan

    row = finding('time_field_read')

    assert_equal :info, row.severity
    assert_includes row.message, 'app/services/snapshot.rb:2'
    assert_includes row.message, 'lib/monitor.rb:1'
    refute_includes row.message, 'snapshot.rb:3', 'a symbol key is an Active Record read, not a job field'
  end

  def test_a_connection_pool_lock_below_wurks_floor_is_a_warning_naming_the_pin
    write('Gemfile', "source 'https://rubygems.org'\ngem 'rails'\ngem 'connection_pool', '~> 2.5'\n")
    write('Gemfile.lock', "GEM\n  specs:\n    connection_pool (2.5.3)\n    rails (8.1.0)\n")

    scan

    row = finding('connection_pool_pin')

    assert_equal :warning, row.severity
    assert_match(/holds connection_pool 2\.5\.3; Wurk needs >= 3\.0, < 4, and Gemfile:3 pins it/, row.message)
  end

  def test_a_lock_inside_wurks_range_is_quiet_and_no_lock_says_how_to_check
    write('Gemfile.lock', "GEM\n  specs:\n    connection_pool (3.0.2)\n")
    scan

    assert_nil finding('connection_pool_pin')

    File.delete(File.join(@root, 'Gemfile.lock'))
    scan

    assert_equal :info, finding('connection_pool_pin').severity
  end

  def test_a_rails_error_subscriber_is_an_info_row
    reporter = Struct.new(:subscribers).new([Object.new])
    reporter.instance_variable_set(:@subscribers, reporter.subscribers)

    with_rails_error(reporter) { scan }

    assert_match(/Rails.error has 1 subscriber\(s\): Object/, finding('rails_error_subscriber').message)
  end

  def test_a_procfile_worker_next_to_a_web_server_that_would_embed_is_a_warning
    write('Procfile.dev', "web: bin/rails server -p 3000\nworker: bundle exec wurkswarm -r .\n")

    scan

    assert_equal :warning, finding('web_would_embed').severity

    write('Procfile.dev', "web: WURK_DISABLED=1 bin/rails server\nworker: bundle exec wurk\n")
    @report = Wurk::Preflight::Report.new('preflight')
    scan

    assert_nil finding('web_would_embed')
  end

  def test_a_flush_in_boot_code_is_a_warning_but_not_in_a_rake_task
    write('config/initializers/sidekiq/server.rb', "Sidekiq.configure_server do |c|\n  c.on(:startup) { " \
                                                   "Sidekiq.redis(&:flushdb) }\nend\n")
    write('lib/tasks/reset.rake', "Sidekiq.redis(&:flushall)\n")

    scan

    row = finding('flush_at_boot')

    assert_equal :warning, row.severity
    assert_includes row.message, 'config/initializers/sidekiq/server.rb:2'
    refute_includes row.message, 'reset.rake'
  end

  def test_a_plugin_off_its_tested_version_is_an_info_row
    scan(specs: { 'sidekiq-cron' => Spec.new('sidekiq-cron', ::Gem::Version.new('2.3.1'), []),
                  'sidekiq-failures' => Spec.new('sidekiq-failures', ::Gem::Version.new('1.1.0'), []) })

    rows = @report.findings.select { |f| f.code == 'plugin_version' }

    assert_equal 1, rows.size
    assert_match(/sidekiq-cron 2\.3\.1 is bundled; its suite runs green against Wurk at 2\.4\.0/, rows.first.message)
  end

  def test_pro_and_ent_guards_are_listed
    write('app/models/a.rb', "if defined?(Sidekiq::Pro)\nend\nSidekiq.ent? && 1\nputs Sidekiq::Pro::VERSION\n")

    scan

    row = finding('pro_ent_guard')

    assert_includes row.message, 'app/models/a.rb:1'
    assert_includes row.message, 'app/models/a.rb:3'
    refute_includes row.message, 'a.rb:4'
  end

  # The pins in lib/ are what test/ecosystem runs; a bump there must move them.
  def test_the_tested_plugin_versions_match_the_ecosystem_pins
    pins = Dir[File.join(ECOSYSTEM, '*', 'PIN')].to_h do |path|
      [File.basename(File.dirname(path)), File.read(path)[/^ref: v?(\S+)$/, 1]]
    end

    assert_equal pins, Wurk::Preflight::AppScan::TESTED_PLUGINS
  end

  private

  def write(path, body)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  def scan(specs: wurk_specs)
    Wurk::Preflight::AppScan.new(root: @root, report: @report, specs: specs).run
  end

  def wurk_specs
    { 'wurk' => Spec.new('wurk', ::Gem::Version.new(Wurk::VERSION),
                         [::Gem::Dependency.new('connection_pool', '>= 3.0', '< 4')]) }
  end

  def finding(code) = @report.findings.find { |f| f.code == code }

  def with_rails_error(reporter)
    rails = Module.new
    rails.define_singleton_method(:error) { reporter }
    had = defined?(::Rails)
    if had
      original = ::Rails.method(:error) if ::Rails.respond_to?(:error)
      ::Rails.define_singleton_method(:error) { reporter }
    else
      Object.const_set(:Rails, rails)
    end
    yield
  ensure
    if had
      original ? ::Rails.define_singleton_method(:error, original) : ::Rails.singleton_class.remove_method(:error)
    else
      Object.send(:remove_const, :Rails)
    end
  end
end
