# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'timeout'
require 'tmpdir'

# Every way of starting workers under Rails has to run jobs inside the Rails
# executor. They reach Processor differently: the runners load the host with no
# railtie at all, the railtie's own swarm forks during app boot, and embedding
# stays in the host process. Real processes, real Redis.
class RailsExecutorBootModesTest < Wurk::Test::UnitCase
  APP = ::File.expand_path('../fixtures/rails_executor_app.rb', __dir__)
  WAIT = 40

  def setup
    super
    @queue = "rails-exec-#{::Process.pid}-#{object_id}"
    @list = "#{@queue}:report"
  end

  def teardown
    Wurk.redis { |c| c.call('DEL', @list, "queue:#{@queue}") }
  ensure
    super
  end

  def test_wurk_runner
    assert_job_ran_in_executor(runner('wurk'), 'RAILS_ENV' => 'test')
  end

  def test_wurkswarm_runner
    assert_job_ran_in_executor(runner('wurkswarm'), 'RAILS_ENV' => 'test', 'WURK_COUNT' => '1')
  end

  def test_swarm_forked_by_the_railtie
    assert_job_ran_in_executor(host_process, host_env)
  end

  def test_embedded_in_the_host_process
    assert_job_ran_in_executor(host_process, host_env.merge('PROBE_EMBED' => '1'))
  end

  # The runner loads the host with no railtie, and a hook in the host's own boot
  # wraps whatever reloader it finds. That has to be the Rails one.
  def test_a_host_hook_wrapping_the_reloader_under_the_runner_keeps_the_executor
    Dir.mktmpdir do |dir|
      ::FileUtils.mkdir_p(::File.join(dir, 'config'))
      ::FileUtils.touch(::File.join(dir, 'config', 'application.rb'))
      ::File.write(::File.join(dir, 'config', 'database.yml'), "test:\n  adapter: sqlite3\n  database: ':memory:'\n")
      ::File.write(::File.join(dir, 'config', 'environment.rb'), <<~RUBY)
        require 'rails'
        require 'active_record/railtie'
        class WrappingHostApp < Rails::Application
          config.root = #{dir.inspect}
          config.eager_load = false
          config.secret_key_base = 'x' * 64
          config.logger = ::Logger.new(IO::NULL)
          config.after_initialize do
            inner = Wurk.configuration[:reloader]
            Wurk.configuration[:reloader] = proc { |&job| inner.call(&job) }
          end
        end
        #{::File.read(APP)[/^class RailsExecutorProbeJob.*?^end$/m]}
        WrappingHostApp.initialize!
      RUBY

      command = [::File.expand_path('../../exe/wurk', __dir__), '-r', dir, '-q', @queue, '-c', '1', '-e', 'test']

      assert_job_ran_in_executor(command, 'RAILS_ENV' => 'test')
    end
  end

  private

  def runner(binary)
    [::File.expand_path("../../exe/#{binary}", __dir__), '-r', APP, '-q', @queue, '-c', '1', '-e', 'test']
  end

  def host_process
    ['-e', "require #{APP.inspect}; sleep"]
  end

  # The test env never boots workers, so this one is development + opted in.
  def host_env
    { 'RAILS_ENV' => 'development', 'WURK_EMBED' => '1', 'WURK_DISABLED' => '0', 'PROBE_SET_QUEUE' => '1' }
  end

  def assert_job_ran_in_executor(command, env)
    push_probe
    report = with_process(command, env) { wait_for_report }

    assert report, "no job ran within #{WAIT}s"
    assert report['executor_active'], 'the job must run inside the Rails executor'
    assert report['query_cache'], 'the executor must have enabled the query cache'
  end

  def push_probe
    payload = { 'class' => 'RailsExecutorProbeJob', 'args' => [@list], 'queue' => @queue, 'retry' => false,
                'jid' => SecureRandom.hex(12), 'created_at' => 1, 'enqueued_at' => 1 }
    Wurk.redis { |c| c.call('LPUSH', "queue:#{@queue}", Wurk.dump_json(payload)) }
  end

  def wait_for_report
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + WAIT
    loop do
      raw = Wurk.redis { |c| c.call('LPOP', @list) }
      return Wurk.load_json(raw) if raw
      return nil if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  def with_process(command, env)
    full_env = { 'REDIS_URL' => Wurk::Test.redis_url, 'PROBE_QUEUE' => @queue, 'COVERAGE' => nil }.merge(env)
    pid = ::Process.spawn(full_env, RbConfig.ruby, '-I', ::File.expand_path('../../lib', __dir__), *command,
                          out: ::File::NULL, err: ::File::NULL, pgroup: true)
    yield
  ensure
    stop(pid)
  end

  def stop(pid)
    ::Process.kill('TERM', pid)
    ::Timeout.timeout(WAIT) { ::Process.wait(pid) }
  rescue ::Timeout::Error
    ::Process.kill('KILL', -pid)
    ::Process.wait(pid)
  end
end
