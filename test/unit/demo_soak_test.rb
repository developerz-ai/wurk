# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../demo/app/jobs/soak_job'
require_relative '../../demo/app/workloads/demo_soak'
require 'open3'
require 'tmpdir'
require 'timeout'

class DemoSoakTest < Wurk::Test::UnitCase
  FLAGS = %w[
    WURK_DEMO WURK_DEMO_SOAK WURK_DEMO_PRODUCER WURK_DISABLED WURK_DEMO_REPORT_ERRORS SENTRY_DSN PORT
  ].freeze
  SOAK_FLAGS = FLAGS.first(4).freeze

  def setup
    super
    @env = FLAGS.to_h { |key| [key, ENV.fetch(key, nil)] }
    SOAK_FLAGS.each { |key| ENV[key] = '1' }
    ENV['PORT'] = '3000'
    @previous = Wurk.configuration
    config = Wurk::Configuration.new
    config.redis = { url: Wurk::Test.redis_url }
    config.logger = Logger.new(IO::NULL)
    config.queues = %w[low default]
    Wurk.instance_variable_set(:@configuration, config)
    Sidekiq::Enterprise.unique!
    config.client_middleware.add(Wurk::Batch::ClientMiddleware)
    config.client_middleware.add(SoakJob::Tagging)
    config.server_middleware.add(Wurk::Batch::ServerMiddleware)
    config.server_middleware.add(Wurk::Limiter::ServerMiddleware)
    @limiter_completions = []
    completions = @limiter_completions
    config.server_middleware.add(Class.new do
      define_method(:call) do |_worker, job, _queue, &block|
        result = block.call
        completions << job['jid'] if job['class'] == 'SoakJob::BucketLimited'
        result
      end
    end)
    @paths = []
    @soak = DemoSoak.new(probe: lambda { |path|
      @paths << path
      true
    })
    @capsule = config.default_capsule
    @capsule.prepare!
    @processor = Wurk::Processor.new(@capsule)
  end

  def teardown
    @capsule.fetcher.flush_pending_acks
    Wurk.redis { |c| c.call('FLUSHDB') }
    Wurk.configuration.reset_redis_pools!
  ensure
    Wurk.instance_variable_set(:@configuration, @previous)
    @env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    super
  end

  def payloads
    raw_payloads = Wurk.redis do |c|
      %w[low default].flat_map { |q| c.call('LRANGE', "queue:#{q}", 0, -1) } +
        %w[schedule retry].flat_map { |key| c.call('ZRANGE', key, 0, -1) }
    end
    raw_payloads.map { |raw| Wurk.load_json(raw) }
  end

  # Minitest 6 no longer supplies Object#stub.
  def with_stub(target, name, replacement)
    original = target.method(name)
    owned = target.singleton_class.method_defined?(name, false)
    implementation = replacement.respond_to?(:call) ? replacement : ->(*) { replacement }
    target.define_singleton_method(name) do |*args, **options, &block|
      implementation.call(*args, **options, &block)
    end
    yield
  ensure
    if owned
      target.define_singleton_method(name, original)
    else
      target.singleton_class.remove_method(name)
    end
  end

  def recorded(token, event)
    Wurk.redis { |c| c.call('GET', "demo-soak:#{token}:#{event}") }
  end

  def drain
    30.times do
      break unless (Wurk::Queue.new('low').size + Wurk::Queue.new('default').size).positive?

      @processor.process_one
    end
    @capsule.fetcher.flush_pending_acks
  end

  def test_cycle_processes_features_and_tags_every_payload_including_callbacks
    assert @soak.tick!
    assert_equal DemoSoak::PATHS, @paths
    jobs = payloads

    assert_equal(1, jobs.count { |j| j['class'] == 'SoakJob::Unique' })
    assert_equal 1, Wurk::ScheduledSet.new.size
    retry_job = jobs.find { |j| j['class'] == 'SoakJob::RetryOnce' }
    token = retry_job.fetch('args').first
    bid = Wurk.redis { |c| c.call('ZRANGE', 'demo-soak:batches', 0, -1) }.first

    assert_operator Wurk.redis { |c| c.call('TTL', "b-#{bid}") }, :<=, SoakJob::TTL
    jobs.each do |job|
      assert_includes job['tags'], 'demo-soak'
      assert_equal 'low', job['queue']
      refute job['dead']
    end
    drain
    retry_entry = Wurk::RetrySet.new.find_job(retry_job['jid'])

    refute_nil retry_entry
    assert_includes retry_entry.item['tags'], 'demo-soak'
    assert_equal 0, Wurk::DeadSet.new.size
    %w[complete success].each { |event| assert_equal '1', recorded(token, "#{event}:#{bid}") }
    assert_equal '1', recorded(token, 'SoakJob::BucketLimited')
    assert_equal 2, @limiter_completions.uniq.size
    assert_equal '1', recorded(token, 'SoakJob::Cron')
    assert_equal '1', recorded('duplicate', 'SoakJob::Unique')
    limited = payloads.find { |job| job['class'] == 'SoakJob::BucketLimited' }

    refute_nil limited
    assert_equal 1, limited['overrated']
    assert_includes limited['tags'], 'demo-soak'
    # Redis owns the bucket clock; reset it before promoting the delayed job.
    Wurk::Limiter.bucket('demo-soak', 2, :minute, wait_timeout: 0).reset
    enq = Wurk::Scheduled::Enq.new(Wurk.configuration)
    enq.define_singleton_method(:real_time) { Time.now.to_f + 120 }
    enq.enqueue_jobs

    payloads.each { |job| assert_includes job['tags'], 'demo-soak' }
    drain

    assert_equal '1', recorded(token, 'SoakJob::RetryOnce')
    assert_equal '1', recorded(token, 'SoakJob')
    assert_includes @limiter_completions, limited.fetch('jid')
    assert_equal 3, @limiter_completions.uniq.size
    2.times { |n| assert_equal '1', recorded("#{token}:#{n}", 'SoakJob::BatchMember') }
    assert_empty payloads
    assert_equal 0, Wurk::DeadSet.new.size
    assert_empty Wurk::Cron::LoopSet.new.to_a
  end

  def test_generated_wrappers_are_marked_but_other_callbacks_are_not
    batch = Wurk::Batch.new
    batch.on(:complete, 'SoakJob::Callback', 'token' => 'callback', 'tags' => ['demo-soak'])
    batch.on(:success, 'SoakJob::Callback', 'token' => 'callback', 'tags' => ['demo-soak'])
    batch.jobs { SoakJob::BatchMember.perform_async('member') }
    @processor.process_one
    wrappers = payloads

    assert_equal 2, wrappers.size
    wrappers.each do |job|
      assert_includes job['tags'], 'demo-soak'
      refute job['dead']
      assert_equal 2, job['retry']
      assert_equal 'low', job['queue']
      assert_includes job['args'].last.fetch('tags'), 'demo-soak'
    end
    foreign = { 'class' => 'Wurk::Batch::CallbackJob', 'args' => ['bid', 'OtherCallback', 'success', {}],
                'retry' => 8, 'dead' => true, 'queue' => 'high' }
    original = foreign.dup
    SoakJob::Tagging.new.call(nil, foreign, 'default') { nil }

    assert_equal original, foreign
  end

  def test_exact_flags_pid_and_failed_probe_prevent_production
    SOAK_FLAGS.each do |key|
      [nil, '0', 'true', '2'].each do |value|
        value.nil? ? ENV.delete(key) : ENV[key] = value

        refute @soak.tick!
      end
      ENV[key] = '1'
    end
    @soak.instance_variable_set(:@pid, Process.pid + 1)

    refute @soak.tick!
    refute @soak.exercise_cron!('forked')
    refute @soak.restart_one_worker!('forked')
    @soak = DemoSoak.new(probe: ->(*) { false })

    refute @soak.tick!
    assert_empty payloads
  end

  def test_run_continues_after_cycle_exception_and_stops_when_disabled
    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| warnings << message }
    soak = DemoSoak.new(logger: logger)
    cycles = 0
    pauses = []
    tick = lambda do
      cycles += 1
      raise IOError, 'probe unavailable' if cycles == 1

      ENV['WURK_DEMO_SOAK'] = '0'
    end
    with_stub(soak, :tick!, tick) do
      with_stub(soak, :sleep, ->(seconds) { pauses << seconds }) { soak.run }
    end

    assert_equal 2, cycles
    assert_equal [DemoSoak::INTERVAL, DemoSoak::INTERVAL], pauses
    assert_equal ['[demo-soak] cycle stopped: IOError: probe unavailable'], warnings
    assert_empty payloads
  end

  def test_run_does_not_tick_or_sleep_when_disabled_or_inherited_by_a_child
    unexpected = ->(*) { flunk 'stopped run loop performed work' }
    with_stub(@soak, :tick!, unexpected) do
      with_stub(@soak, :sleep, unexpected) do
        ENV['WURK_DEMO_SOAK'] = '0'
        @soak.run
        ENV['WURK_DEMO_SOAK'] = '1'
        @soak.instance_variable_set(:@pid, Process.pid + 1)
        @soak.run
      end
    end

    assert_empty payloads
  end

  def test_memory_boundaries_and_probe_failure
    connection = Object.new
    value = "used_memory:79\r\nmaxmemory:100\r\n"
    connection.define_singleton_method(:call) { |*| value }
    with_stub(Wurk, :redis, ->(&block) { block.call(connection) }) do
      assert_predicate @soak, :memory_safe?
      value = "used_memory:80\r\nmaxmemory:100\r\n"

      refute_predicate @soak, :memory_safe?
      refute @soak.tick!
      value = "used_memory:#{DemoSoak::ABSOLUTE_MEMORY_LIMIT - 1}\r\nmaxmemory:0\r\n"

      assert_predicate @soak, :memory_safe?
      value = "used_memory:#{DemoSoak::ABSOLUTE_MEMORY_LIMIT}\r\nmaxmemory:0\r\n"

      refute @soak.tick!
      maximum = DemoSoak::ABSOLUTE_MEMORY_LIMIT * 2
      value = "used_memory:#{DemoSoak::ABSOLUTE_MEMORY_LIMIT - 1}\r\nmaxmemory:#{maximum}\r\n"

      assert_predicate @soak, :memory_safe?
      value = "used_memory:#{DemoSoak::ABSOLUTE_MEMORY_LIMIT}\r\nmaxmemory:#{maximum}\r\n"

      refute_predicate @soak, :memory_safe?
      refute @soak.tick!
      [nil, {}, '', "used_memory:oops\r\n", "used_memory:1\r\n",
       "used_memory:-1\r\nmaxmemory:100\r\n", "used_memory:1\r\nmaxmemory:-1\r\n"].each do |bad|
        value = bad

        refute @soak.tick!
      end
      value = "used_memory:1\r\nmaxmemory:100\r\n"

      assert_predicate @soak, :memory_safe?
    end
    with_stub(Wurk, :redis, ->(*) { raise IOError, 'probe unavailable' }) { refute @soak.tick! }
    assert_empty payloads
    assert_empty @paths
  end

  def test_cron_cannot_produce_autonomously_or_when_disabled_or_under_pressure
    loop_obj = Wurk::Cron.register('demo soak', '* * * * *', 'SoakJob::Cron', ['old'], queue: 'low')
    poller = Wurk::Cron::Poller.new(Wurk.configuration)
    poller.send(:enqueue!, loop_obj)

    assert_empty payloads
    ENV['WURK_DEMO_SOAK'] = '0'
    @soak.exercise_cron!('disabled')

    assert_empty payloads
    ENV['WURK_DEMO_SOAK'] = '1'
    with_stub(DemoSoak, :new, @soak) do
      with_stub(@soak, :memory_safe?, false) { @soak.exercise_cron!('pressure') }
    end

    assert_empty payloads
    assert_nil Thread.current[:demo_soak_cron]
  end

  def test_cron_restores_existing_thread_guard_on_early_returns_and_enqueue
    previous = Thread.current[:demo_soak_cron]
    marker = Object.new
    Thread.current[:demo_soak_cron] = marker
    ENV['WURK_DEMO_SOAK'] = '0'

    refute @soak.exercise_cron!('disabled')
    assert_same marker, Thread.current[:demo_soak_cron]
    ENV['WURK_DEMO_SOAK'] = '1'
    @soak.instance_variable_set(:@pid, Process.pid + 1)

    refute @soak.exercise_cron!('forked')
    assert_same marker, Thread.current[:demo_soak_cron]
    assert_empty payloads
    @soak.instance_variable_set(:@pid, Process.pid)
    @soak.exercise_cron!('admitted')

    assert_same marker, Thread.current[:demo_soak_cron]
    assert_equal(['SoakJob::Cron'], payloads.map { |job| job['class'] })
  ensure
    Thread.current[:demo_soak_cron] = previous
  end

  def test_backlog_reserves_exactly_twelve_slots_across_queues_and_sorted_sets
    Wurk.redis do |c|
      %w[high default low].each { |queue| 5.times { c.call('LPUSH', "queue:#{queue}", 'queued') } }
      %w[retry schedule].each do |key|
        6.times { |n| c.call('ZADD', key, n, "pending-#{n}") }
      end
    end

    assert_predicate @soak, :backlog_safe?
    Wurk.redis { |c| c.call('LPUSH', 'queue:low', 'boundary') }

    refute_predicate @soak, :backlog_safe?
    refute @soak.tick!
    assert_empty @paths
  end

  def test_backlog_and_batch_count_are_bounded_and_expired_indexes_are_pruned
    DemoSoak::BACKLOG_LIMIT.times { SoakJob.perform_async('backlog') }

    refute @soak.tick!
    Wurk.redis { |c| c.call('DEL', 'queue:low') }
    DemoSoak::BATCH_LIMIT.times do |n|
      Wurk.redis do |c|
        c.call('SET', "b-#{n}", 'live', 'EX', 300)
        c.call('ZADD', 'demo-soak:batches', n, n)
      end
    end

    refute @soak.tick!
    Wurk.redis do |c|
      c.call('DEL', 'b-0')
      c.call('ZADD', 'batches', 0, '0')
    end

    assert @soak.tick!
    assert_nil(Wurk.redis { |c| c.call('ZSCORE', 'batches', '0') })
  end

  def test_dashboard_probe_is_get_only_with_deadlines_and_rejects_bad_responses
    response = Struct.new(:code, :body).new('200', '{}')
    http = Object.new
    requests = []
    http.define_singleton_method(:request) do |request|
      requests << request
      response
    end
    start = lambda do |host, port, **options, &block|
      assert_equal '127.0.0.1', host
      assert_equal 3000, port
      assert_equal({ open_timeout: 1, read_timeout: 1, write_timeout: 1 }, options)
      block.call(http)
    end
    with_stub(Net::HTTP, :start, start) do
      assert @soak.send(:dashboard_get, DemoSoak::PATHS.first)
      response.body = 'not json'

      refute @soak.send(:dashboard_get, DemoSoak::PATHS.first)
      response.code = '302'

      refute @soak.send(:dashboard_get, DemoSoak::PATHS.first)
    end
    assert_equal 3, requests.size
    requests.each do |request|
      assert_instance_of Net::HTTP::Get, request
      assert_includes DemoSoak::PATHS, request.path
    end
  end

  def test_restart_targets_only_the_worker_running_the_original_jid
    workers = [
      Wurk::Process.new('identity' => 'embedded', 'tag' => 'demo', 'embedded' => true, 'beat' => Time.now.to_f),
      Wurk::Process.new('identity' => 'foreign', 'tag' => 'other', 'beat' => Time.now.to_f),
      Wurk::Process.new('identity' => 'stale', 'tag' => 'demo', 'beat' => 1),
      Wurk::Process.new('identity' => 'demo-one', 'tag' => 'demo', 'beat' => Time.now.to_f),
      Wurk::Process.new('identity' => 'demo-two', 'tag' => 'demo', 'beat' => Time.now.to_f)
    ]
    with_stub(SoakJob::Recovery, :perform_async, 'original') do
      wait = ->(seconds, &) { seconds == 5 ? '["demo-two","original"]' : 'original' }
      with_stub(@soak, :wait_for, wait) do
        with_stub(Wurk::ProcessSet, :new, workers) { assert @soak.restart_one_worker!('target') }
      end
    end

    assert_equal(['TERM'], Wurk.redis { |c| c.call('LRANGE', 'demo-two-signals', 0, -1) })
    %w[embedded foreign stale demo-one].each do |id|
      assert_equal(0, Wurk.redis { |c| c.call('EXISTS', "#{id}-signals") })
    end
  end

  def test_stop_request_without_original_jid_completion_is_not_verified
    worker = Wurk::Process.new('identity' => 'demo', 'tag' => 'demo', 'beat' => Time.now.to_f)
    with_stub(SoakJob::Recovery, :perform_async, 'original') do
      [nil, 'substitute'].each do |completion|
        wait = ->(seconds, &) { seconds == 5 ? '["demo","original"]' : completion }
        with_stub(@soak, :wait_for, wait) do
          with_stub(Wurk::ProcessSet, :new, [worker]) { refute @soak.restart_one_worker!('unverified') }
        end
      end
    end

    assert_equal(%w[TERM TERM], Wurk.redis { |c| c.call('LRANGE', 'demo-signals', 0, -1) })
  end

  def test_initializer_gates_threads_without_opening_parent_redis_connections
    script = <<~RUBY
      require 'wurk'
      require 'wurk/web'
      require_relative 'demo/app/workloads/demo_soak'
      module Rails
        def self.logger = nil
        def self.application = self
        def self.config = self
        def self.after_initialize(&block) = (@callbacks ||= []) << block
        def self.callbacks = @callbacks || []
        def self.reset = @callbacks = []
      end
      class DemoProducer
        def initialize(**); end
        def run = nil
      end
      class DemoSoak
        def run = ($soak_runs += 1)
      end
      def Wurk.redis(*) = raise('initializer opened Redis')
      def Thread.new(&block) = block.call
      flags = %w[WURK_DEMO WURK_DEMO_SOAK WURK_DEMO_PRODUCER WURK_DISABLED]
      [nil, *flags].each do |disabled|
        flags.each { |key| ENV[key] = key == disabled ? '0' : '1' }
        Rails.reset
        $soak_runs = 0
        load 'demo/config/initializers/wurk.rb'
        raise 'queue priority changed' unless Wurk.configuration.queues == %w[high default low]
        raise 'dashboard mutable' unless Wurk::Web.config.read_only?
        if disabled.nil?
          child = fork do
            Rails.callbacks.each(&:call)
            exit!($soak_runs.zero? ? 0 : 1)
          end
          _, status = Process.waitpid2(child)
          raise 'fork produced soak' unless status.success?
        end
        Rails.callbacks.each(&:call)
        raise 'flag gate failed' unless $soak_runs == (disabled.nil? ? 1 : 0)
      end
      puts 'initializer gates verified'
    RUBY
    output, status = Open3.capture2e({ 'COVERAGE' => nil }, RbConfig.ruby, '-Ilib', '-e', script)

    assert_predicate status, :success?, output
    assert_includes output, 'initializer gates verified'
  end

  def test_real_swarm_restart_recovers_and_completes_original_tagged_jid
    script = <<~'RUBY'
      require 'wurk'
      require 'timeout'
      require_relative 'demo/app/jobs/soak_job'
      require_relative 'demo/app/workloads/demo_soak'
      $stdout.sync = true
      config = Wurk.configuration
      config.redis = { url: ENV.fetch('SOAK_TEST_REDIS_URL') }
      config.logger = Logger.new($stdout)
      config[:tag] = 'demo'
      config[:timeout] = 1
      config.queues = %w[high default low]
      config.client_middleware.add(SoakJob::Tagging)
      class RecoveryEvidence
        def call(_worker, job, _queue)
          return yield unless job['class'] == 'SoakJob::Recovery'

          identity = Wurk::Component.identity
          Wurk.redis do |c|
            jobs = c.call('KEYS', 'queue:*|*').flat_map { |key| c.call('LRANGE', key, 0, -1) }
            held = jobs.map { |raw| Wurk.load_json(raw) }.find { |payload| payload['jid'] == job['jid'] }
            raise 'original tagged payload not in custody' unless held && held.fetch('tags').include?('demo-soak')
            raise 'recovery payload untagged' unless job.fetch('tags').include?('demo-soak')
            c.call('RPUSH', 'demo-soak:test-executions', Wurk.dump_json([identity, job['jid']]))
          end
          yield
        end
      end
      config.server_middleware.add(RecoveryEvidence)
      topology = Wurk::Topology.flat(count: 1, queues: %w[high default low], concurrency: 1)
      supervisor = fork do
        swarm = Wurk::Swarm.new(topology: topology, shutdown_timeout: 1)
        begin
          swarm.boot
          swarm.supervise
        ensure
          swarm.shutdown
        end
      end
      begin
        soak = DemoSoak.new(logger: config.logger)
        raise 'worker did not boot' unless soak.wait_for(15) { Wurk::ProcessSet.new(false).first }
        token = 'supervised-restart'
        # TERM exercises deadline requeue plus supervisor respawn, not orphan reclamation.
        raise 'producer did not verify recovery' unless soak.restart_one_worker!(token)
        started = Wurk.redis { |c| c.call('GET', "demo-soak:#{token}:started") }
        identity, jid = Wurk.load_json(started)
        executions = Wurk.redis { |c| c.call('LRANGE', 'demo-soak:test-executions', 0, -1) }
        executions.map! { |raw| Wurk.load_json(raw) }
        raise "unexpected executions: #{executions.inspect}" unless executions.size == 2
        raise 'first identity/JID changed' unless executions.first == [identity, jid]
        replacement, completed_jid = executions.last
        raise 'worker was not replaced' if replacement == identity
        raise 'substitute job completed' unless completed_jid == jid
        recovered = Wurk.redis { |c| c.call('GET', "demo-soak:#{token}:recovered") }
        raise 'original JID not completed' unless recovered == jid
        released = soak.wait_for(10) do
          Wurk.redis do |c|
            keys = c.call('KEYS', 'queue:*')
            jobs = keys.flat_map { |key| c.call('LRANGE', key, 0, -1) }
            jobs.none? { |raw| Wurk.load_json(raw)['jid'] == jid }
          end
        end
        raise 'original JID still in fetch custody' unless released
        replacement_worker = Wurk::ProcessSet.new(false).find { |worker| worker.identity == replacement }
        raise 'replacement heartbeat missing' unless replacement_worker
        puts "supervised recovery verified: #{identity} -> #{replacement}, JID #{jid}"
      ensure
        Process.kill('TERM', supervisor)
        Timeout.timeout(15) { Process.waitpid(supervisor) }
      end
    RUBY
    env = { 'COVERAGE' => nil, 'SOAK_TEST_REDIS_URL' => Wurk::Test.redis_url }
    Dir.mktmpdir do |dir|
      diagnostics = File.join(dir, 'swarm.log')
      child = Process.spawn(env, RbConfig.ruby, '-Ilib', '-e', script,
                            out: diagnostics, err: %i[child out], pgroup: true)
      begin
        _, status = Timeout.timeout(90) { Process.waitpid2(child) }
        output = File.read(diagnostics)

        assert_predicate status, :success?, output
        assert_includes output, 'supervised recovery verified:'
      rescue Timeout::Error => e
        flunk "#{e.full_message}\nSwarm diagnostics:\n#{File.read(diagnostics)}"
      ensure
        begin
          Process.kill('KILL', -child)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.waitpid(child)
        rescue Errno::ECHILD
          nil
        end
      end
    end
  end

  def test_entrypoint_preserves_opt_in_and_clears_inherited_producer_flag_for_other_roles
    Dir.mktmpdir do |dir|
      script = "#!/bin/sh\nprintf '%s:%s' \"${WURK_DEMO_PRODUCER-unset}\" \"${WURK_DEMO_SOAK-unset}\"\n"
      File.write(File.join(dir, 'bundle'), script)
      File.chmod(0o755, File.join(dir, 'bundle'))
      [nil, '1', 'true'].each do |flag|
        env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}",
                'WURK_DEMO_PRODUCER' => '1', 'WURK_DEMO_SOAK' => flag, 'COVERAGE' => nil }
        %w[web worker bundle].each do |role|
          output, status = Open3.capture2(env, 'bash', 'bin/demo-entrypoint', role)

          assert_predicate status, :success?
          assert_equal "#{role == 'web' ? '1' : 'unset'}:#{flag || 'unset'}", output
        end
      end
    end
  end

  def test_sentry_actual_scope_is_isolated_from_suite_global_sdk
    script = <<~'RUBY'
      require 'wurk'
      require 'sentry-ruby'
      ENV['WURK_DEMO'] = '1'
      ENV['WURK_DEMO_SOAK'] = '0'
      ENV['WURK_DEMO_REPORT_ERRORS'] = '1'
      ENV['SENTRY_DSN'] = 'http://public@localhost/1'
      load 'demo/config/initializers/sentry.rb'
      raise 'PII enabled' unless Sentry.configuration.send_default_pii == false
      filter = Sentry.configuration.before_send
      raise 'central policy bypassed' unless filter == DemoSentryPolicy.method(:before_send)
      Sentry.init do |config|
        config.dsn = 'http://public@localhost/1'
        config.background_worker_threads = 0
        config.enabled_patches = []
        config.transport.transport_class = Sentry::DummyTransport
        config.before_send = filter
      end
      chain = Wurk.configuration.default_capsule.server_middleware
      [true, false].each do |marked|
        job = { 'class' => 'Wurk::Batch::CallbackJob', 'jid' => 'scope', 'args' => [], 'retry' => false }
        job['tags'] = ['demo-soak'] if marked
        begin
          chain.invoke(nil, job, 'low') { raise 'callback failure' }
        rescue RuntimeError => e
          raise unless e.message == 'callback failure'
        end
      end
      events = Sentry.get_current_client.transport.events
      unless events.size == 1 && !events.first.tags.key?('demo-soak')
        raise "marker leaked or marked error reported: #{events.map { |event| event.tags }.inspect}"
      end
      %w[BrokenJob FlakyWebhookJob].each do |klass|
        event = Sentry::Event.new(configuration: Sentry.configuration)
        event.contexts = { Wurk::Sentry::JobContext::CONTEXT_KEY => { 'class' => klass } }
        raise 'showcase failure reported' unless filter.call(event, {}).nil?
      end
      Sentry.close
      puts 'scope isolation verified'
    RUBY
    env = { 'COVERAGE' => nil, 'SENTRY_DSN' => nil }
    Open3.popen2e(env, RbConfig.ruby, '-Ilib', '-e', script) do |stdin, out, wait|
      stdin.close
      begin
        output = Timeout.timeout(15) { out.read }

        assert_predicate wait.value, :success?, output
        assert_includes output, 'scope isolation verified'
      ensure
        Process.kill('KILL', wait.pid) if wait.alive?
      end
    end
  end
end
