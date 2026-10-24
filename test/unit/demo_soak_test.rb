# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../demo/app/jobs/soak_job"
require_relative "../../demo/app/workloads/demo_soak"
require "wurk/sentry"
require "open3"
require "tmpdir"
require "timeout"

class DemoSoakTest < Wurk::Test::UnitCase
  FLAGS = %w[WURK_DEMO WURK_DEMO_SOAK WURK_DEMO_PRODUCER WURK_DISABLED WURK_DEMO_REPORT_ERRORS SENTRY_DSN].freeze

  def setup
    super
    @env = FLAGS.to_h { |key| [key, ENV[key]] }
    FLAGS.first(4).each { |key| ENV[key] = "1" }
    @previous = Wurk.configuration
    config = Wurk::Configuration.new
    config.redis = { url: Wurk::Test.redis_url }
    config.logger = Logger.new(IO::NULL)
    config.queues = ["low", "default"]
    Wurk.instance_variable_set(:@configuration, config)
    Sidekiq::Enterprise.unique!
    config.client_middleware.add(SoakJob::Tagging)
    @paths = []
    @soak = DemoSoak.new(probe: ->(path) { @paths << path; true })
    @capsule = config.default_capsule
    @capsule.prepare!
    @processor = Wurk::Processor.new(@capsule)
  end

  def teardown
    @capsule.fetcher.flush_pending_acks
    Wurk.redis { |c| c.call("FLUSHDB") }
    Wurk.configuration.reset_redis_pools!
    Wurk.instance_variable_set(:@configuration, @previous)
    @env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    super
  end

  def payloads
    Wurk.redis do |c|
      %w[low default].flat_map { |q| c.call("LRANGE", "queue:#{q}", 0, -1) } +
        %w[schedule retry].flat_map { |key| c.call("ZRANGE", key, 0, -1) }
    end.map { |raw| Wurk.load_json(raw) }
  end

  def drain
    30.times do
      break if Wurk::Queue.new("low").size.zero? && Wurk::Queue.new("default").size.zero?

      @processor.process_one
    end
    @capsule.fetcher.flush_pending_acks
  end

  def test_cycle_processes_features_and_tags_every_payload_including_callbacks
    assert @soak.tick!
    assert_equal DemoSoak::PATHS, @paths
    jobs = payloads
    assert_equal 1, jobs.count { |j| j["class"] == "SoakJob::Unique" }
    assert_equal 1, Wurk::ScheduledSet.new.size
    retry_job = jobs.find { |j| j["class"] == "SoakJob::RetryOnce" }
    token = retry_job.fetch("args").first
    bid = Wurk.redis { |c| c.call("ZRANGE", "demo-soak:batches", 0, -1) }.first
    assert_operator Wurk.redis { |c| c.call("TTL", "b-#{bid}") }, :<=, SoakJob::TTL
    jobs.each { |job| assert_includes job["tags"], "demo-soak" }
    drain
    retry_entry = Wurk::RetrySet.new.find_job(retry_job["jid"])
    assert retry_entry
    assert_includes retry_entry.item["tags"], "demo-soak"
    assert_equal 0, Wurk::DeadSet.new.size
    %w[complete success].each do |event|
      assert_equal "1", Wurk.redis { |c| c.call("GET", "demo-soak:#{token}:#{event}:#{bid}") }
    end
    assert_equal "1", Wurk.redis { |c| c.call("GET", "demo-soak:#{token}:SoakJob::BucketLimited") }
    assert_includes Wurk.redis { |c| c.call("SMEMBERS", "lmtr-list") }, "demo-soak"
    # Promote through the real scheduler without a wall-clock wait.
    enq = Wurk::Scheduled::Enq.new(Wurk.configuration)
    enq.define_singleton_method(:real_time) { Time.now.to_f + 120 }
    enq.enqueue_jobs
    payloads.each { |job| assert_includes job["tags"], "demo-soak" }
    drain
    assert_equal "1", Wurk.redis { |c| c.call("GET", "demo-soak:#{token}:SoakJob::RetryOnce") }
    assert_equal "1", Wurk.redis { |c| c.call("GET", "demo-soak:#{token}:SoakJob") }
    loop_obj = Wurk::Cron::LoopSet.new.to_a.fetch(0)
    Wurk::Cron::Poller.new(Wurk.configuration).send(:enqueue!, loop_obj)
    assert_includes payloads.first["tags"], "demo-soak"
    drain
    assert_equal "1", Wurk.redis { |c| c.call("GET", "demo-soak:minute:SoakJob::Cron") }
    assert @soak.tick!
    assert_equal 1, Wurk::Cron::LoopSet.new.to_a.size
  end

  def test_generated_wrappers_are_marked_but_other_callbacks_are_not
    batch = Wurk::Batch.new
    batch.on(:complete, "SoakJob::Callback", "token" => "callback", "tags" => ["demo-soak"])
    batch.on(:success, "SoakJob::Callback", "token" => "callback", "tags" => ["demo-soak"])
    batch.jobs { SoakJob::BatchMember.perform_async("member") }
    @processor.process_one
    wrappers = payloads
    assert_equal 2, wrappers.size
    wrappers.each do |job|
      assert_includes job["tags"], "demo-soak"
      assert_equal false, job["dead"]
      assert_includes job["args"].last.fetch("tags"), "demo-soak"
    end
    foreign = { "class" => "Wurk::Batch::CallbackJob", "args" => ["bid", "OtherCallback", "success", {}] }
    SoakJob::Tagging.new.call(nil, foreign, "default") { nil }
    refute foreign.key?("tags")
  end

  def test_exact_flags_pid_and_failed_probe_prevent_production
    FLAGS.first(4).each do |key|
      [nil, "0", "true", "2"].each do |value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
        refute @soak.tick!
      end
      ENV[key] = "1"
    end
    @soak.instance_variable_set(:@pid, Process.pid + 1)
    refute @soak.tick!
    @soak = DemoSoak.new(probe: ->(*) { false })
    refute @soak.tick!
    assert_empty payloads
  end

  def test_memory_boundaries_and_probe_failure
    connection = Object.new
    value = "used_memory:79\r\nmaxmemory:100\r\n"
    connection.define_singleton_method(:call) { |*| value }
    Wurk.stub(:redis, ->(&block) { block.call(connection) }) do
      assert @soak.memory_safe?
      value = "used_memory:80\r\nmaxmemory:100\r\n"
      refute @soak.memory_safe?
      value = "used_memory:#{DemoSoak::ABSOLUTE_MEMORY_LIMIT - 1}\r\nmaxmemory:0\r\n"
      assert @soak.memory_safe?
      value = "used_memory:#{DemoSoak::ABSOLUTE_MEMORY_LIMIT}\r\nmaxmemory:0\r\n"
      refute @soak.memory_safe?
      value = "used_memory:oops\r\n"
      refute @soak.memory_safe?
      value = "used_memory:1\r\nmaxmemory:100\r\n"
      assert @soak.memory_safe?
    end
    Wurk.stub(:redis, ->(*) { raise IOError, "probe unavailable" }) { refute @soak.memory_safe? }
  end

  def test_backlog_and_batch_count_are_bounded_and_expired_indexes_are_pruned
    DemoSoak::BACKLOG_LIMIT.times { SoakJob.perform_async("backlog") }
    refute @soak.tick!
    Wurk.redis { |c| c.call("DEL", "queue:low") }
    DemoSoak::BATCH_LIMIT.times do |n|
      Wurk.redis do |c|
        c.call("SET", "b-#{n}", "live", "EX", 300)
        c.call("ZADD", "demo-soak:batches", n, n)
      end
    end
    refute @soak.tick!
    Wurk.redis do |c|
      c.call("DEL", "b-0")
      c.call("ZADD", "batches", 0, "0")
    end
    assert @soak.tick!
    assert_nil Wurk.redis { |c| c.call("ZSCORE", "batches", "0") }
  end

  def test_dashboard_probe_is_get_only_with_deadlines_and_rejects_bad_responses
    response = Struct.new(:code, :body).new("200", "{}")
    http = Object.new
    http.define_singleton_method(:request) do |request|
      raise "not GET" unless request.is_a?(Net::HTTP::Get)
      raise "wrong path" unless DemoSoak::PATHS.include?(request.path)

      response
    end
    start = lambda do |host, port, **options, &block|
      assert_equal "127.0.0.1", host
      assert_equal 3000, port
      assert_equal({ open_timeout: 1, read_timeout: 1, write_timeout: 1 }, options)
      block.call(http)
    end
    Net::HTTP.stub(:start, start) do
      assert @soak.send(:dashboard_get, DemoSoak::PATHS.first)
      response.body = "not json"
      refute @soak.send(:dashboard_get, DemoSoak::PATHS.first)
      response.code = "302"
      refute @soak.send(:dashboard_get, DemoSoak::PATHS.first)
    end
  end

  def test_restart_signals_only_one_live_nonembedded_demo_worker
    workers = [
      Wurk::Process.new("identity" => "embedded", "tag" => "demo", "embedded" => true, "beat" => Time.now.to_f),
      Wurk::Process.new("identity" => "foreign", "tag" => "other", "beat" => Time.now.to_f),
      Wurk::Process.new("identity" => "stale", "tag" => "demo", "beat" => 1),
      Wurk::Process.new("identity" => "demo-one", "tag" => "demo", "beat" => Time.now.to_f),
      Wurk::Process.new("identity" => "demo-two", "tag" => "demo", "beat" => Time.now.to_f)
    ]
    Wurk::ProcessSet.stub(:new, workers) { @soak.restart_one_worker! }
    assert_equal ["TERM"], Wurk.redis { |c| c.call("LRANGE", "demo-one-signals", 0, -1) }
    %w[embedded foreign stale demo-two].each do |id|
      assert_equal 0, Wurk.redis { |c| c.call("EXISTS", "#{id}-signals") }
    end
  end

  def test_real_worker_restart_recovers_original_tagged_jid_from_private_list
    jid = SoakJob.perform_async("recovery")
    reader, writer = IO.pipe
    Wurk.configuration.reset_redis_pools!
    child = fork do
      reader.close
      Wurk.configuration.reset_redis_pools!
      capsule = Wurk.configuration.default_capsule
      unit = capsule.fetcher.retrieve_work
      writer.write(unit.job)
      writer.close
      exit! 0
    end
    writer.close
    raw = Timeout.timeout(5) { reader.read }
    Process.waitpid(child)
    child = nil
    assert_equal jid, Wurk.load_json(raw)["jid"]
    assert_includes Wurk.load_json(raw)["tags"], "demo-soak"
    assert_equal 0, Wurk::Queue.new("low").size
    assert_equal 1, Wurk::Fetcher::Reaper.new(Wurk.configuration, grace: 0).reclaim!
    assert_equal jid, payloads.first["jid"]
    # Replacement processor executes the recovered payload, not a newly pushed job.
    replacement = Wurk::Processor.new(@capsule)
    replacement.process_one
    @capsule.fetcher.flush_pending_acks
    assert_equal "1", Wurk.redis { |c| c.call("GET", "demo-soak:recovery:SoakJob") }
  ensure
    reader&.close
    writer&.close unless writer&.closed?
    if child
      Process.kill("KILL", child)
      Process.waitpid(child)
    end
  end

  def test_entrypoint_clears_inherited_producer_flag_for_other_roles
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "bundle"), "#!/bin/sh\nprintf '%s:%s' \"${WURK_DEMO_PRODUCER-unset}\" \"${WURK_DEMO_SOAK-unset}\"\n")
      File.chmod(0o755, File.join(dir, "bundle"))
      env = { "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "WURK_DEMO_PRODUCER" => "1", "WURK_DEMO_SOAK" => nil }
      %w[web worker].each do |role|
        output, status = Open3.capture2(env, "bash", "bin/demo-entrypoint", role)
        assert status.success?
        assert_equal(role == "web" ? "1:unset" : "unset:unset", output)
      end
      output, status = Open3.capture2(env, "bash", "bin/demo-entrypoint", "bundle")
      assert status.success?
      assert_equal "unset:unset", output
    end
  end

  def test_sentry_actual_scope_drops_marked_wrapper_and_retains_unmarked_wrapper
    require "sentry-ruby"
    ENV["WURK_DEMO_REPORT_ERRORS"] = "1"
    load File.expand_path("../../demo/config/initializers/sentry.rb", __dir__)
    filter = Sentry.configuration.before_send
    Sentry.init do |config|
      config.dsn = "http://public@localhost/1"
      config.background_worker_threads = 0
      config.enabled_patches = []
      config.transport.transport_class = Sentry::DummyTransport
      config.before_send = filter
    end
    chain = Wurk.configuration.server_middleware
    [true, false].each do |marked|
      job = { "class" => "Wurk::Batch::CallbackJob", "jid" => "scope", "args" => [], "retry" => false }
      job["tags"] = ["demo-soak"] if marked
      assert_raises(RuntimeError) do
        chain.invoke(nil, job, "low") { raise "callback failure" }
      end
    end
    events = Sentry.get_current_client.transport.events
    assert_equal 1, events.size
    refute events.first.tags.key?("demo-soak")
    %w[BrokenJob FlakyWebhookJob].each do |klass|
      event = Sentry::Event.new
      event.contexts = { Wurk::Sentry::JobContext::CONTEXT_KEY => { "class" => klass } }
      assert_nil filter.call(event, {})
    end
  ensure
    Sentry.close if defined?(Sentry) && Sentry.initialized?
  end
end
