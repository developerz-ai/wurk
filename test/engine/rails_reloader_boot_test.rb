# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'tmpdir'

# Scenarios that need their own Rails boot: a host initializer, code reloading
# on, or a deliberately undersized Active Record pool. Each runs in a subprocess
# so it can't disturb the shared dummy app, under a hard time limit so that a
# deadlock fails the test instead of hanging the suite.
class RailsReloaderBootTest < Wurk::Test::UnitCase
  parallelize_me!

  LIB = ::File.expand_path('../../lib', __dir__)
  DUMMY = ::File.expand_path('../dummy/config/application', __dir__)
  LIMIT = 60

  # Boots the dummy with code reloading on and defines `run_workers`, which
  # drives real Processors, one per thread, over real Redis.
  HARNESS = <<~RUBY.freeze
    require #{DUMMY.inspect}
    require "timeout"

    def configure_host(reloading: true, autoload: nil)
      Dummy::Application.config.autoload_paths << autoload if autoload
      Dummy::Application.config.before_initialize do |app|
        app.config.enable_reloading = reloading
      end
      Rails.application.initialize!
      Wurk.configuration.logger = ::Logger.new(IO::NULL)
    end

    def capsule_for(queue)
      capsule = Wurk::Capsule.new("t", Wurk.configuration)
      capsule.queues = [queue]
      capsule.fetcher = Wurk::Fetcher::Reliable.new(capsule)
      capsule
    end

    def push(capsule, queue, klass, *args)
      payload = { "class" => klass, "args" => args, "queue" => queue, "retry" => false,
                  "jid" => SecureRandom.hex(12), "created_at" => 1 }
      capsule.redis_pool.with { |c| c.call("LPUSH", "queue:\#{queue}", Wurk.dump_json(payload)) }
    end

    def run_workers(capsule, count)
      Timeout.timeout(#{LIMIT - 15}) do
        Array.new(count) { Thread.new { Wurk::Processor.new(capsule).process_one } }.each(&:join)
      end
    end
  RUBY

  # --- boot order ---------------------------------------------------------

  def test_boot_sees_what_a_host_after_initialize_hook_configured
    Dir.mktmpdir do |dir|
      ::File.write(::File.join(dir, 'host.rb'), <<~RUBY)
        Rails.application.config.after_initialize do
          Wurk.configuration.redis = { url: 'redis://host-configured:6379/1' }
        end
      RUBY

      output = run_ruby(<<~RUBY)
        #{HARNESS}
        Dummy::Application.paths['config/initializers'] << #{dir.inspect}
        Wurk::RailsBoot.define_singleton_method(:boot) do |_app = nil|
          puts "BOOT:\#{Wurk.configuration.redis_config[:url]}"
        end
        Rails.application.initialize!
      RUBY

      assert_includes output, 'BOOT:redis://host-configured:6379/1'
    end
  end

  def test_a_host_hook_can_wrap_the_installed_reloader
    Dir.mktmpdir do |dir|
      ::File.write(::File.join(dir, 'host.rb'), <<~RUBY)
        Rails.application.config.after_initialize do
          $wrapped = Wurk.configuration[:reloader]
        end
      RUBY

      output = run_ruby(<<~RUBY)
        #{HARNESS}
        Dummy::Application.paths['config/initializers'] << #{dir.inspect}
        Rails.application.initialize!
        puts "WRAPPED:\#{$wrapped.class}"
      RUBY

      assert_includes output, 'WRAPPED:Wurk::RailsReloader'
    end
  end

  # Workers embedded from an initializer freeze the config before the railtie
  # installs anything. Boot has to survive that, and their jobs still need the
  # executor once the app is up.
  def test_workers_embedded_from_an_initializer_survive_boot_and_get_the_executor
    Dir.mktmpdir do |dir|
      queue = "embed-init-#{::Process.pid}-#{object_id}"
      ::File.write(::File.join(dir, 'embed.rb'), embedding_initializer(queue))

      output = run_ruby(<<~RUBY)
        #{HARNESS}
        Dummy::Application.paths['config/initializers'] << #{dir.inspect}
        Rails.application.initialize!
        puts "FROZEN:\#{Wurk.configuration.frozen?}"
        job = { "class" => "EmbeddedProbeJob", "args" => [], "queue" => #{queue.inspect}, "retry" => false,
                "jid" => SecureRandom.hex(12), "created_at" => 1 }
        Wurk.redis { |c| c.call("LPUSH", "queue:#{queue}", Wurk.dump_json(job)) }
        puts "EXECUTOR:\#{Timeout.timeout(20) { $seen.pop }}"
        $embedded.stop
      RUBY

      assert_includes output, 'FROZEN:true'
      assert_includes output, 'EXECUTOR:true'
    end
  end

  # The initializer list is built by then, so the Finisher entry never runs.
  def test_requiring_the_railtie_from_an_initializer_still_boots_workers
    Dir.mktmpdir do |dir|
      ::File.write(::File.join(dir, 'late.rb'), <<~RUBY)
        require 'wurk/rails'
        Wurk::RailsBoot.define_singleton_method(:boot) { |_app = nil| puts 'BOOTED' }
      RUBY

      output = run_ruby(<<~RUBY)
        require "wurk"
        require "rails"
        require "action_controller/railtie"
        class LateRailtieApp < Rails::Application
          config.root = #{dir.inspect}
          config.eager_load = false
          config.secret_key_base = "x" * 64
          config.logger = ::Logger.new(IO::NULL)
          paths['config/initializers'] << #{dir.inspect}
        end
        LateRailtieApp.initialize!
      RUBY

      assert_includes output, 'BOOTED'
    end
  end

  # --- reloading ----------------------------------------------------------

  def test_changed_code_is_reloaded_between_jobs
    Dir.mktmpdir do |dir|
      output = run_ruby(<<~RUBY)
        #{HARNESS}
        dir = #{dir.inspect}
        file = File.join(dir, "reloadable_probe_job.rb")
        write = lambda do |version, mtime|
          File.write(file, "class ReloadableProbeJob; include Wurk::Job; def perform; puts 'RAN:\#{version}'; end; end")
          File.utime(mtime, mtime, file)
        end
        write.call("v1", Time.now - 60)
        configure_host(autoload: dir)
        queue = "reload-\#{Process.pid}"
        capsule = capsule_for(queue)
        push(capsule, queue, "ReloadableProbeJob")
        run_workers(capsule, 1)
        write.call("v2", Time.now - 30)
        push(capsule, queue, "ReloadableProbeJob")
        run_workers(capsule, 1)
      RUBY

      assert_includes output, 'RAN:v1'
      assert_includes output, 'RAN:v2', 'a job must pick up code changed since the previous job'
    end
  end

  def test_jobs_calling_reload_do_not_deadlock_beside_other_running_jobs
    output = run_ruby(<<~RUBY)
      #{HARNESS}
      configure_host
      class ReloadingJob
        include Wurk::Job
        def perform(reload)
          Rails.application.reloader.reload! if reload
          sleep 0.2
          $finished << reload
        end
      end
      $finished = Queue.new
      queue = "reload-dl-\#{Process.pid}"
      capsule = capsule_for(queue)
      [true, true, false, false].each { |reload| push(capsule, queue, "ReloadingJob", reload) }
      run_workers(capsule, 4)
      puts "FINISHED:\#{$finished.size}"
    RUBY

    assert_includes output, 'FINISHED:4'
  end

  # --- Active Record pool smaller than the job thread count ---------------

  def test_more_job_threads_than_connections_all_finish
    output = run_ruby(<<~RUBY)
      #{HARNESS}
      configure_host(reloading: false)
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:", pool: 1, checkout_timeout: 10)
      class PoolJob
        include Wurk::Job
        def perform
          ActiveRecord::Base.connection.execute("SELECT 1")
          sleep 0.05
          $finished << 1
        end
      end
      $finished = Queue.new
      queue = "pool-\#{Process.pid}"
      capsule = capsule_for(queue)
      6.times { push(capsule, queue, "PoolJob") }
      run_workers(capsule, 6)
      puts "FINISHED:\#{$finished.size}"
    RUBY

    assert_includes output, 'FINISHED:6'
  end

  # A job holding the only connection waits in reload! for a job that is itself
  # waiting for that connection. Bounded by checkout_timeout, not a deadlock.
  def test_reload_waiting_on_a_job_waiting_for_a_connection_resolves_by_checkout_timeout
    output = run_ruby(<<~RUBY)
      #{HARNESS}
      configure_host
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:", pool: 1, checkout_timeout: 1)
      class HoldAndReloadJob
        include Wurk::Job
        def perform(reload)
          ActiveRecord::Base.connection.execute("SELECT 1")
          sleep 0.3
          Rails.application.reloader.reload! if reload
        end
      end
      queue = "pool-dl-\#{Process.pid}"
      capsule = capsule_for(queue)
      push(capsule, queue, "HoldAndReloadJob", true)
      push(capsule, queue, "HoldAndReloadJob", false)
      run_workers(capsule, 2)
      puts "DONE"
    RUBY

    assert_includes output, 'DONE'
  end

  # --- the runners -------------------------------------------------------

  # `wurk` and `wurkswarm` require wurk before Rails exists, so no railtie ever
  # loads and nothing installs config[:reloader]. Processor still finds the app.
  def test_a_host_booted_with_no_railtie_still_gets_the_rails_reloader
    Dir.mktmpdir do |dir|
      output = run_ruby(<<~RUBY)
        require "wurk"
        require "rails"
        class NoRailtieApp < Rails::Application
          config.root = #{dir.inspect}
          config.eager_load = false
          config.secret_key_base = "x" * 64
          config.logger = ::Logger.new(IO::NULL)
        end
        NoRailtieApp.initialize!
        capsule = Wurk::Capsule.new("t", Wurk.configuration)
        puts "RAILTIE:\#{defined?(Wurk::Railtie).inspect}"
        puts "DEFAULT:\#{Wurk.configuration[:reloader].equal?(Wurk::Configuration::DEFAULTS[:reloader])}"
        puts "RELOADER:\#{Wurk::Processor.new(capsule).instance_variable_get(:@reloader).class}"
      RUBY

      assert_includes output, 'RAILTIE:nil'
      assert_includes output, 'DEFAULT:true'
      assert_includes output, 'RELOADER:Wurk::RailsReloader'
    end
  end

  # --- outside Rails ------------------------------------------------------

  def test_a_plain_ruby_worker_gets_no_wrapping_and_loads_no_rails
    output = run_ruby(<<~RUBY)
      require "wurk"
      capsule = Wurk::Capsule.new("t", Wurk::Configuration.new)
      reloader = Wurk::Processor.new(capsule).instance_variable_get(:@reloader)
      puts "RELOADER:\#{reloader.name}"
      puts "RAILS:\#{defined?(::Rails).inspect}"
    RUBY

    assert_includes output, 'RELOADER:Wurk::Processor::IdentityReloader'
    assert_includes output, 'RAILS:nil'
  end

  def test_rails_loaded_with_no_application_gets_no_wrapping
    output = run_ruby(<<~RUBY)
      require "rails"
      require "wurk"
      puts "DEFAULT:\#{Wurk::RailsReloader.default.inspect}"
    RUBY

    assert_includes output, 'DEFAULT:nil'
  end

  private

  def embedding_initializer(queue)
    <<~RUBY
      class EmbeddedProbeJob
        include Wurk::Job
        def perform = $seen << Rails.application.executor.active?
      end
      $seen = Queue.new
      $embedded = Wurk.configure_embed do |config|
        config.queues = [#{queue.inspect}]
        config.concurrency = 1
        config.logger = ::Logger.new(IO::NULL)
      end
      $embedded.run
    RUBY
  end

  def run_ruby(script)
    env = { 'REDIS_URL' => Wurk::Test.redis_url, 'RAILS_ENV' => 'test', 'WURK_DISABLED' => '1', 'COVERAGE' => nil }
    output, status = Open3.capture2e(env, 'timeout', LIMIT.to_s, RbConfig.ruby, '-I', LIB, '-e', script)

    assert_predicate status, :success?, "subprocess failed:\n#{output}"
    output
  end
end
