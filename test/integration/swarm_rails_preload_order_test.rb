# frozen_string_literal: true

require_relative '../test_helper'
require 'bundler'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'securerandom'
require 'timeout'
require 'tmpdir'

# Real `wurkswarm` on minimal Rails apps with their own Gemfile, so the group preload
# is a real Bundler.require. A Rails target has two shapes that need opposite orders:
#   - config/application.rb uses a gem it expects the swarm to have preloaded,
#     which is what stock sidekiqswarm's order (preload, then app) gives it;
#   - a gem needs Rails loaded at require time, which is what the normal
#     application.rb order (framework, then Bundler.require) gives it.
class SwarmRailsPreloadOrderTest < Wurk::Test::UnitCase
  ROOT = File.expand_path('../..', __dir__)
  WURKSWARM = File.join(ROOT, 'exe', 'wurkswarm')
  BOOT_TIMEOUT = 30

  def setup
    super
    @dir = Dir.mktmpdir('wurk-preload-order')
    @events = File.join(@dir, 'events.log')
    File.write(@events, '')
    write_gem('preload_me', 'module PreloadMe; def self.ready = true; end')
    write_gem('needs_rails', 'NeedsRailsName = ActiveModel::Name')
    write_gemfile
  end

  def teardown
    (@swarm_pid &&= ::Process.kill('KILL', -@swarm_pid))
  rescue Errno::ESRCH
    nil
  ensure
    FileUtils.remove_entry(@dir)
    super
  end

  # The adopter's shape: the app skips Bundler.require because the swarm ran it.
  def test_an_app_that_needs_the_preload_boots
    write_app(before_class: 'PreloadMe.ready', gem_group: :preload)

    assert_boots
    assert_equal 1, count('loaded preload_me'), 'the gem must load exactly once in the process that runs'
  end

  # The half-run case an in-process retry would get wrong: the class body had already
  # registered an initializer and middleware when the constant went missing.
  def test_a_failure_halfway_through_the_class_body_leaves_nothing_registered_twice
    write_app(in_class: <<~RUBY, gem_group: :preload)
      config.after_initialize { File.write(ENV.fetch('EVENTS'), "after_initialize\\n", mode: 'a') }
      class OnceMiddleware; def initialize(app) = @app = app; end
      config.middleware.use OnceMiddleware
      PreloadMe.ready
    RUBY
    write_environment_extra(<<~'RUBY')
      stack = Rails.application.middleware.middlewares.count { |m| m.klass.name.end_with?('OnceMiddleware') }
      File.write(ENV.fetch('EVENTS'), "middleware=#{stack}\n", mode: 'a')
    RUBY

    assert_boots
    assert_equal 1, count('after_initialize')
    assert_equal 1, count('middleware=1')
  end

  def test_a_gem_that_needs_rails_at_require_time_boots
    write_app(gem_group: :needs_rails, frameworks: "require 'active_model/railtie'\n",
              bundler_require: 'Bundler.require(:needs_rails)')

    assert_boots(preload: 'needs_rails')
    assert_equal 1, count('loaded needs_rails')
  end

  # An app with the usual Bundler.require loads once, in one process: no cost for
  # the apps that never needed any of this.
  def test_an_ordinary_app_is_not_booted_twice
    write_app(gem_group: :preload, bundler_require: 'Bundler.require(:preload)')

    assert_boots
    assert_equal 1, count('application.rb')
  end

  def test_a_genuine_app_bug_surfaces_with_its_own_message_and_fails
    write_app(before_class: 'NoSuchConstantInThisApp.call', gem_group: :preload)

    output, status = run_to_exit

    refute_predicate status, :success?
    assert_includes output, 'NoSuchConstantInThisApp'
    assert_equal 2, count('application.rb'), 'one retry, not a loop'
    assert_equal 0, count('startup')
  end

  # Without the note the second error could read as the cause when the first one was.
  def test_when_the_retry_fails_too_both_errors_are_shown
    write_app(before_class: 'NoSuchConstantInThisApp.call', gem_group: :needs_rails)

    output, status = run_to_exit(preload: 'needs_rails')

    refute_predicate status, :success?
    assert_includes output, 'NoSuchConstantInThisApp'
    assert_includes output, 'ActiveModel'
  end

  # A re-exec has to find wurkswarm from any of these, and `$0` is not it: `bundle exec`
  # loads the binstub in-process, so argv0 is Bundler's executable, and for the last
  # shape it is `-e`.
  LAUNCHES = {
    'bundle_exec' => ->(t) { [t.bundle_env, 'bundle', 'exec', 'wurkswarm'] },
    'binstub' => ->(t) { [t.binstub_env, './bin/wurkswarm'] },
    'load_bin_path' => lambda { |t|
      [t.bundle_env, RbConfig.ruby, '-rbundler/setup', '-e', "load Gem.bin_path('wurk', 'wurkswarm')", '--']
    },
    'load_under_bundle_exec' => lambda { |t|
      [t.bundle_env, 'bundle', 'exec', 'ruby', '-e', "load Gem.bin_path('wurk', 'wurkswarm')", '--']
    },
    'direct_exe' => ->(t) { [t.bundle_env.merge('RUBYOPT' => '-rbundler/setup'), WURKSWARM] }
  }.freeze
  DOT = ['-e', 'production', '-r', '.'].freeze
  ENVIRONMENT_RB = ['-e', 'production', '-r', 'config/environment.rb'].freeze

  def bundle_env
    path = Bundler.settings[:path]
    { 'BUNDLE_GEMFILE' => File.join(@dir, 'Gemfile'), 'BUNDLE_PATH' => path && File.expand_path(path, ROOT),
      'BUNDLE_APP_CONFIG' => File.join(@dir, '.bundle'), 'RUBYOPT' => nil, 'COVERAGE' => nil }
  end

  def binstub_env
    bundle_env.merge('BUNDLE_GEMFILE' => nil, 'PATH' => "#{RbConfig::CONFIG['bindir']}:#{ENV.fetch('PATH')}")
  end

  def assert_retry_runs_a_job(shape, flags)
    write_app(before_class: 'PreloadMe.ready', gem_group: :preload)
    prepare_binstub if shape == 'binstub'
    pid = spawn_swarm(LAUNCHES.fetch(shape).call(self) + flags)
    wait_for('startup', pid)
    enqueue_job
    wait_for('performed', pid)

    assert_equal 2, count('application.rb'), 'one retry'
    assert_equal [pid], pids_seen.uniq, 'the retry keeps the pid a supervisor is watching'
    assert stop(pid), 'swarm did not drain on TERM'
  end

  LAUNCHES.each_key do |shape|
    define_method("test_#{shape}_retries_boots_and_runs_a_job") { assert_retry_runs_a_job(shape, DOT) }
  end

  def test_a_require_of_the_environment_file_retries_too
    assert_retry_runs_a_job('bundle_exec', ENVIRONMENT_RB)
  end

  %w[bundle_exec load_bin_path].each do |shape|
    define_method("test_#{shape}_shows_a_genuine_bug_and_fails") do
      write_app(before_class: 'NoSuchConstantInThisApp.call', gem_group: :preload)
      env, *argv = LAUNCHES.fetch(shape).call(self)
      env = env.merge('EVENTS' => @events, 'WURK_PRELOAD' => 'preload', 'REDIS_URL' => Wurk::Test.redis_url)
      output = IO.popen([env, *argv, *DOT, { chdir: @dir, err: %i[child out] }], &:read)

      refute_predicate ::Process.last_status, :success?, output
      assert_includes output, 'NoSuchConstantInThisApp'
      assert_includes output, 'config/application.rb:', 'the app bug keeps its location'
      assert_equal 2, count('application.rb')
    end
  end

  # An app bug past the retry path, the case the short failure line hid.
  def test_a_bug_in_the_environment_file_shows_its_file_and_line
    write_app(gem_group: :preload, bundler_require: 'Bundler.require(:preload)')
    write_environment_extra('nil.frobnicate')
    env, *argv = LAUNCHES.fetch('bundle_exec').call(self)
    env = env.merge('EVENTS' => @events, 'WURK_PRELOAD' => 'preload', 'REDIS_URL' => Wurk::Test.redis_url)
    output = IO.popen([env, *argv, *DOT, { chdir: @dir, err: %i[child out] }], &:read)

    refute_predicate ::Process.last_status, :success?
    assert_includes output, 'frobnicate'
    assert_match(%r{config/environment\.rb:\d+}, output)
  end

  # Before the swarm has installed anything the retried process has only Ruby's own
  # handlers, and a TERM then must end it rather than be lost across the exec.
  def test_a_term_right_after_the_retry_ends_the_process
    slow_retry = "sleep 30 if File.read(ENV.fetch('EVENTS')).scan('application.rb').size > 1\nPreloadMe.ready"
    write_app(before_class: slow_retry, gem_group: :preload)
    pid = spawn_swarm(LAUNCHES.fetch('bundle_exec').call(self) + DOT)
    deadline = now + BOOT_TIMEOUT
    sleep 0.01 until count('application.rb') == 2 || now > deadline
    ::Process.kill('TERM', pid)
    _, status = Timeout.timeout(20) { ::Process.wait2(pid) }

    refute_predicate status, :success?
    assert_equal 0, count('startup')
  end

  private

  def now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

  def prepare_binstub
    output = IO.popen([bundle_env, 'bundle', 'binstubs', 'wurk', { chdir: @dir, err: %i[child out] }], &:read)

    assert_predicate ::Process.last_status, :success?, output
  end

  def spawn_swarm(command)
    env, *argv = command
    @log = File.join(@dir, 'swarm.log')
    env = { 'EVENTS' => @events, 'WURK_PRELOAD' => 'preload', 'WURK_COUNT' => '1', 'REDIS_URL' => Wurk::Test.redis_url,
            'RAILS_ENV' => nil }.merge(env)
    @swarm_pid = ::Process.spawn(env, *argv, chdir: @dir, out: @log, err: %i[child out], pgroup: true)
  end

  def wait_for(event, pid)
    deadline = now + BOOT_TIMEOUT
    until count(event).positive?
      flunk "swarm exited before #{event}:\n#{File.read(@log)}" if ::Process.wait(pid, ::Process::WNOHANG)
      flunk "no #{event} in time:\n#{File.read(@log)}" if now > deadline
      sleep 0.05
    end
  end

  def enqueue_job
    payload = { 'class' => 'PreloadOrderJob', 'args' => [], 'jid' => SecureRandom.hex(12), 'queue' => 'default',
                'retry' => false, 'created_at' => Time.now.to_f, 'enqueued_at' => Time.now.to_f }
    Wurk.redis do |conn|
      conn.call('SADD', 'queues', 'default')
      conn.call('LPUSH', 'queue:default', JSON.generate(payload))
    end
  end

  def pids_seen = File.readlines(@events, chomp: true).filter_map { |line| line[/\Apid=(\d+)/, 1]&.to_i }

  def write_gem(name, body)
    dir = File.join(@dir, 'gems', name)
    FileUtils.mkdir_p(File.join(dir, 'lib'))
    File.write(File.join(dir, "#{name}.gemspec"), <<~RUBY)
      Gem::Specification.new do |s|
        s.name = #{name.inspect}
        s.version = '1.0.0'
        s.summary = 'fixture'
        s.authors = ['fixture']
        s.files = ['lib/#{name}.rb']
      end
    RUBY
    File.write(File.join(dir, 'lib', "#{name}.rb"), <<~RUBY)
      File.write(ENV.fetch('EVENTS'), "loaded #{name}\\n", mode: 'a')
      #{body}
    RUBY
  end

  def write_gemfile
    File.write(File.join(@dir, 'Gemfile'), <<~RUBY)
      eval_gemfile #{File.join(ROOT, 'Gemfile').inspect}
      group(:preload) { gem 'preload_me', path: 'gems/preload_me' }
      group(:needs_rails) { gem 'needs_rails', path: 'gems/needs_rails' }
    RUBY
    FileUtils.cp(File.join(ROOT, 'Gemfile.lock'), File.join(@dir, 'Gemfile.lock'))
    install = [bundle_env, 'bundle', 'install', '--local', '--quiet', { chdir: @dir, err: %i[child out] }]
    output = IO.popen(install, &:read)

    assert_predicate ::Process.last_status, :success?, output
  end

  def write_app(gem_group:, before_class: '', in_class: '', frameworks: '', bundler_require: '')
    FileUtils.mkdir_p(File.join(@dir, 'config'))
    File.write(File.join(@dir, 'config/application.rb'), <<~RUBY)
      File.write(ENV.fetch('EVENTS'), "application.rb\\npid=\#{Process.pid}\\n", mode: 'a')
      require 'logger'
      require 'rails'
      #{frameworks}require 'action_controller/railtie'
      #{bundler_require}
      #{before_class}
      class PreloadOrderApp < Rails::Application
        config.root = #{@dir.inspect}
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.secret_key_base = 'x' * 64
        #{in_class}
      end
    RUBY
    write_environment_extra('')
    @gem_group = gem_group
  end

  def write_environment_extra(extra)
    File.write(File.join(@dir, 'config/environment.rb'), <<~RUBY)
      require_relative 'application'
      Rails.application.initialize!
      #{extra}
      Sidekiq.configure_server do |config|
        config.redis = { url: ENV.fetch('REDIS_URL') }
        config.on(:startup) { File.write(ENV.fetch('EVENTS'), "startup\\n", mode: 'a') }
      end
      class PreloadOrderJob
        include Sidekiq::Job
        def perform = File.write(ENV.fetch('EVENTS'), "performed\\n", mode: 'a')
      end
    RUBY
  end

  def swarm_env(preload)
    bundle_env.merge('EVENTS' => @events, 'WURK_PRELOAD' => preload, 'WURK_COUNT' => '1', 'RAILS_ENV' => 'production',
                     'REDIS_URL' => Wurk::Test.redis_url)
  end

  def swarm_command = [RbConfig.ruby, '-rbundler/setup', WURKSWARM, '-r', @dir]

  def assert_boots(preload: 'preload')
    log = File.join(@dir, 'swarm.log')
    pid = @swarm_pid = ::Process.spawn(swarm_env(preload), *swarm_command, chdir: @dir, out: log, err: %i[child out],
                                                                           pgroup: true)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
    until count('startup').positive?
      exited = ::Process.wait(pid, ::Process::WNOHANG)
      flunk "swarm exited:\n#{File.read(log)}" if exited
      flunk "swarm never started:\n#{File.read(log)}" if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
    pid_stopped = stop(pid)

    assert pid_stopped, 'swarm did not drain on TERM'
  end

  def stop(pid)
    ::Process.kill('TERM', pid)
    Timeout.timeout(30) { ::Process.wait(pid) }
    true
  rescue Timeout::Error
    ::Process.kill('KILL', -pid)
    ::Process.wait(pid)
    false
  end

  def run_to_exit(preload: 'preload')
    output = IO.popen([swarm_env(preload), *swarm_command, { chdir: @dir, err: %i[child out] }], &:read)

    [output, ::Process.last_status]
  end

  def count(event)
    File.readlines(@events, chomp: true).count(event)
  end
end
