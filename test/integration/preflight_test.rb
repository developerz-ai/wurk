# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/preflight/command'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'socket'
require 'tmpdir'
require 'uri'

# Real Redis throughout. Command stats are server-wide, so the read-only proofs
# run against a redis-server of their own (skipped when there is no binary).
class PreflightTest < Wurk::Test::UnitCase
  EXE = File.expand_path('../../exe/wurk', __dir__)

  def setup
    super
    @out = StringIO.new
    @err = StringIO.new
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: Wurk::Test.redis_url }
    @redis = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @redis&.close
    @config&.reset_redis_pools!
    stop_private_server
    ENV.delete('WURK_DISABLED')
  ensure
    super
  end

  # --- exit status and output ---------------------------------------------

  def test_a_quiet_redis_with_keys_is_clean
    @redis.call('SET', 'an-app-key', '1')

    assert_equal 0, command('preflight', '--pause-ms', '0')
    assert_match(/clean/, @out.string)
  end

  def test_an_empty_keyspace_is_a_finding_for_both_commands
    %w[preflight verify].each do |name|
      assert_equal 1, command(name, '--pause-ms', '0')
      assert_match(/empty_keyspace/, @out.string)
      refute_match(/: clean\z/, @out.string.strip)
    end
  end

  def test_both_commands_print_the_target_without_credentials
    url = start_private_server
    @private.call('CONFIG', 'SET', 'requirepass', 's3cretpw')
    secured = url.sub('redis://', 'redis://:s3cretpw@')

    %w[preflight verify].each do |name|
      [[], ['--json']].each do |flags|
        @out = StringIO.new
        Wurk::Preflight::Command.run([name, '-u', secured, '--pause-ms', '0', *flags], config: @config, out: @out,
                                                                                       err: @err)

        assert_includes @out.string, URI(url).port.to_s
        refute_includes @out.string + @err.string, 's3cretpw'
      end
    end
    @private = RedisClient.config(url: secured, timeout: 5).new_client
  end

  def test_no_credential_reaches_any_error_path
    ['redis://user:s3cretpw@host:notaport/0', 'redis://user:s3cretpw@127.0.0.1:1/0', 'nonsense://u:s3cretpw@h/0',
     'redis://u:s3cretpw with space@h/0'].each do |url|
      out, status = Open3.capture2e({ 'REDIS_URL' => 'redis://other:s3cretpw@127.0.0.1:1/0' }, ::RbConfig.ruby,
                                    EXE, 'preflight', '-u', url)

      assert_equal 2, status.exitstatus, out
      refute_includes out, 's3cretpw'
    end
  end

  def test_an_unexpected_error_exits_2_and_never_1
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'raises.rb')
      File.write(path, "raise 'boom at redis://u:s3cretpw@h:1/0'\n")
      out, status = Open3.capture2e({ 'REDIS_URL' => Wurk::Test.redis_url }, ::RbConfig.ruby, EXE, 'preflight',
                                    '--app', path)

      assert_equal 2, status.exitstatus, out
      assert_includes out, 'boom'
      refute_includes out, 's3cretpw'
    end
  end

  def test_a_frozen_config_still_takes_a_redis_url
    @redis.call('SET', 'an-app-key', '1')
    @config.freeze!

    assert_equal 0, Wurk::Preflight::Command.run(['preflight', '-u', Wurk::Test.redis_url, '--pause-ms', '0'],
                                                 config: @config, out: @out, err: @err), @err.string
  end

  def test_a_binary_private_list_key_is_reported_not_fatal
    @redis.call('LPUSH', "queue:\xFFbin|h|1|aaaaaaaaaaaa|0".b, job('j'))
    @redis.call('LPUSH', "queue:\xFEodd|nope".b, job('k'))

    [%w[--json], []].each do |flags|
      assert_equal 1, command('preflight', '--pause-ms', '0', *flags), @err.string
      assert_predicate @out.string, :valid_encoding?
    end
  end

  # --- a real Rails app ---------------------------------------------------

  def test_app_boots_a_rails_app_without_a_swarm_and_reads_its_server_redis
    Dir.mktmpdir do |dir|
      marker = rails_fixture(dir)
      @redis.call('SET', 'an-app-key', '1')
      env = rails_env(marker).merge('REDIS_URL' => 'redis://127.0.0.1:1/0', 'APP_REDIS_URL' => Wurk::Test.redis_url)
      stdout, stderr, status = Open3.capture3(env, ::RbConfig.ruby, EXE, 'preflight', '--app', dir, '--json')
      seen = JSON.parse(File.read(marker))
      doc = JSON.parse(stdout)

      assert_includes [0, 1], status.exitstatus, stderr
      assert_equal '1', seen['disabled_at_load'], 'WURK_DISABLED must be set before the app loads'
      assert seen['skip_boot'], 'the railtie must not boot a swarm'
      assert_empty seen['children'], 'no forked child'
      assert_includes stderr, 'runs its initializers'
      assert_includes codes(doc), 'app_code_ran'
      assert_equal URI(Wurk::Test.redis_url).port, doc.dig('sections', 'target', 'port')
      assert_equal URI(Wurk::Test.redis_url).path.delete('/').to_i, doc.dig('sections', 'target', 'db')
      assert_equal 0, @redis.call('SCARD', 'processes')
    end
  end

  def test_the_rails_fixture_would_fork_a_swarm_if_not_disabled
    Dir.mktmpdir do |dir|
      marker = rails_fixture(dir)
      env = rails_env(marker).merge('REDIS_URL' => Wurk::Test.redis_url, 'APP_REDIS_URL' => Wurk::Test.redis_url)
      pid = Process.spawn(env, ::RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e',
                          "require #{File.join(dir, 'config/environment').inspect}; sleep 30",
                          out: IO::NULL, err: IO::NULL, pgroup: true)
      begin
        wait_until(timeout: 25) { File.exist?(marker) && @redis.call('SCARD', 'processes').positive? }

        refute JSON.parse(File.read(marker))['skip_boot'], 'control: this boot is allowed to fork'
      ensure
        Process.kill('-TERM', pid)
        Process.wait(pid)
      end
    end
  end

  def test_app_code_is_called_out_in_the_report_and_on_stderr
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app.rb')
      File.write(path, "# app code\n")

      assert_includes codes(run_doc('preflight', '--app', path)), 'app_code_ran'
      assert_includes @err.string, 'not read-only'
    end
  end

  def test_a_run_with_no_warnings_is_not_called_clean_if_app_code_ran
    report = Wurk::Preflight::Report.new('preflight')
    report.info(Wurk::Preflight::Report::APP_CODE_RAN, 'ran')

    refute_match(/preflight: clean/, report.to_text)
    assert_match(/app code ran/, report.to_text)
  end

  def test_json_output_carries_sections_and_findings
    @redis.call('LPUSH', 'queue:q|gone-host|1|aaaaaaaaaaaa|0', job('j1'))

    assert_equal 1, command('preflight', '--json', '--pause-ms', '0')
    doc = JSON.parse(@out.string)

    assert_equal 'findings', doc['status']
    assert_equal 1, doc.dig('sections', 'private_lists', 'reclaimable')
    assert_includes codes(doc), 'reclaimable_lists'
  end

  def test_an_unreachable_redis_exits_2
    status = Wurk::Preflight::Command.run(['preflight', '--redis-url', 'redis://127.0.0.1:1/0'],
                                          config: @config, out: @out, err: @err)

    assert_equal 2, status
    assert_match(/cannot read Redis/, @err.string)
  end

  def test_a_bad_option_exits_2_with_usage
    assert_equal 2, command('preflight', '--nope')
    assert_match(/wurk preflight \[options\]/, @err.string)
  end

  # --- private lists ------------------------------------------------------

  def test_private_lists_are_classified
    @redis.call('SADD', 'queues', 'q', 'has|pipe')
    @redis.call('LPUSH', 'queue:has|pipe', job('public'))
    @redis.call('LPUSH', 'queue:q|gone|4242|aaaaaaaaaaaa|0', job('dead-5'))
    @redis.call('LPUSH', 'queue:q|gone|4242|0', job('dead-4'))
    @redis.call('LPUSH', 'queue:q|livehost|77|bbbbbbbbbbbb|0', job('live-5'))
    @redis.call('LPUSH', 'queue:q|livehost|78|0', job('live-4'))
    @redis.call('LPUSH', 'queue:sq|gone:1:abc|q', job('odd'))
    beat('livehost:77:bbbbbbbbbbbb')
    beat('livehost:78:cccccccccccc')

    doc = run_doc('preflight')
    lists = doc.dig('sections', 'private_lists')

    assert_equal [2, 2, 1], lists.values_at('owner_alive', 'reclaimable', 'unparseable')
    assert_includes codes(doc), 'unparseable_lists'
    assert_includes codes(doc), 'reclaimable_lists'
  end

  # --- payloads -----------------------------------------------------------

  def test_timestamp_shapes_and_retry_for_are_counted
    @redis.call('SADD', 'queues', 'q')
    @redis.call('LPUSH', 'queue:q', job('s', 'created_at' => 1_793_625_000.5, 'enqueued_at' => 1_793_625_000.6))
    @redis.call('LPUSH', 'queue:q', job('m', 'created_at' => 1_793_625_000_500, 'retry_for' => 60))
    @redis.call('ZADD', 'retry', 1, job('r', 'failed_at' => 1_793_625_000_500))

    doc = run_doc('preflight')
    payloads = doc.dig('sections', 'payloads')

    assert_equal [2, 2, 1, 3], payloads.values_at('seconds', 'millis', 'retry_for', 'sampled')
    assert_includes codes(doc), 'retry_for'
    refute_includes warnings(doc), 'millis_timestamps'
  end

  def test_millis_with_a_stock_process_live_is_a_finding
    @redis.call('SADD', 'queues', 'q')
    @redis.call('LPUSH', 'queue:q', job('m', 'created_at' => 1_793_625_000_500))
    beat('stock:1:aaaaaaaaaaaa', cores: false, version: '7.3.10')

    assert_includes warnings(run_doc('preflight')), 'millis_timestamps'
  end

  def test_encrypt_without_an_envelope_is_a_finding_and_never_prints_args
    @redis.call('SADD', 'queues', 'q')
    @redis.call('LPUSH', 'queue:q', job('blob', 'encrypt' => true, 'args' => %w[pub c2VjcmV0LXZhbHVl]))
    @redis.call('LPUSH', 'queue:q', job('env', 'encrypt' => true, 'args' => ['pub', envelope]))

    doc = run_doc('preflight')

    assert_includes warnings(doc), 'encrypt_without_envelope'
    assert_equal [1, 1], doc.dig('sections', 'payloads').values_at('encrypt_without_envelope', 'sealed')
    assert_includes codes(doc), 'sealed_payloads'
    refute_includes @out.string, 'c2VjcmV0LXZhbHVl'
  end

  def test_a_payload_that_is_not_a_job_is_counted_not_fatal
    @redis.call('SADD', 'queues', 'q')
    @redis.call('LPUSH', 'queue:q', 'not json', '[1,2]')

    assert_equal 2, run_doc('preflight').dig('sections', 'payloads', 'unparseable')
  end

  # --- batches and locks --------------------------------------------------

  def test_in_flight_batch_without_callbacks_is_a_finding
    @redis.call('HSET', 'b-bare', 'pending', '2', 'total', '2')
    @redis.call('HSET', 'b-with', 'pending', '1', 'callbacks', '[]')
    @redis.call('HSET', 'b-done', 'pending', '0')
    @redis.call('SADD', 'b-bare-jids', 'a')
    @redis.call('SET', 'b-stringy', 'x')

    doc = run_doc('preflight')

    assert_equal [3, 2, 1], doc.dig('sections', 'batches').values_at('inspected', 'in_flight', 'without_callbacks')
    assert_includes warnings(doc), 'batch_without_callbacks'
  end

  def test_lock_counts_and_sha1_digests
    @redis.call('SET', "unique:#{'a' * 40}", 'j')
    @redis.call('SET', "unique:#{'b' * 64}", 'j')
    @redis.call('SET', 'unique:other', 'j')
    @redis.call('SET', "uniquejobs:#{'c' * 32}", 'j')
    @redis.call('HSET', "uniquejobs:#{'c' * 32}:LOCKED", 'j', '1')
    @redis.call('ZADD', 'uniquejobs:digests', 1, 'x')

    doc = run_doc('preflight')

    assert_equal({ 'unique_sha1' => 1, 'unique_sha256' => 1, 'unique_other' => 1, 'gem_locks' => 1, 'gem_keys' => 3 },
                 doc.dig('sections', 'locks'))
    assert_includes warnings(doc), 'unique_sha1'
    assert_includes codes(doc), 'gem_locks'
  end

  # --- the keyspace walk stays bounded ------------------------------------

  def test_limit_truncates_and_says_so
    keys = Array.new(2500) { |i| "k#{i}" }
    keys.each_slice(500) { |slice| @redis.call('MSET', *slice.flat_map { |k| [k, 1] }) }
    progress = []

    keyspace = Wurk::Preflight::Keyspace.new(reader, limit: 1000, pause: 0, progress: ->(m) { progress << m }).walk

    assert_predicate keyspace, :truncated?
    assert_operator keyspace.scanned, :<, 2500
    assert_includes warnings(run_doc('preflight', '--limit', '1000')), 'scan_truncated'
  end

  def test_progress_reports_every_hundred_thousand_keys
    progress = []
    keyspace = Wurk::Preflight::Keyspace.new(nil, limit: 1, pause: 0, progress: ->(m) { progress << m })

    keyspace.send(:report_progress, 99_999)

    assert_empty progress
    keyspace.send(:report_progress, 2)

    assert_equal ['scanned 100001 keys'], progress
  end

  # --- app checks ---------------------------------------------------------

  def test_known_broken_gems_and_a_released_sidekiq_are_findings
    report = Wurk::Preflight::Report.new('preflight')
    specs = { 'sidekiq-status' => Object.new,
              'sidekiq' => Struct.new(:full_gem_path, :version).new('/gems/sidekiq-7.3.10', '7.3.10') }

    checks_for(report).app(specs: specs)
    codes = report.findings.map(&:code)

    assert_includes codes, 'known_broken_gem'
    assert_includes codes, 'real_sidekiq_gem'
  end

  def test_the_shim_is_not_mistaken_for_a_released_sidekiq
    report = Wurk::Preflight::Report.new('preflight')
    specs = { 'sidekiq' => Struct.new(:full_gem_path, :version).new('/x/ecosystem/sidekiq-shim', '8.1.5') }

    checks_for(report).app(specs: specs)

    refute_includes report.findings.map(&:code), 'real_sidekiq_gem'
  end

  def test_app_option_loads_a_file_and_lists_ignored_locks
    skip 'sidekiq-unique-jobs is loaded here' if defined?(::SidekiqUniqueJobs)

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'locked_app.rb')
      File.write(path, <<~RUBY)
        class PreflightLockedJob
          include Wurk::Worker
          sidekiq_options lock: :until_executed
        end
      RUBY

      assert_includes warnings(run_doc('preflight', '--app', path)), 'ignored_lock'
    end
  end

  def test_app_option_takes_an_app_directory
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'config'))
      File.write(File.join(dir, 'config/environment.rb'), "$preflight_app_booted = true\n")

      run_doc('preflight', '--app', dir)

      assert $preflight_app_booted # rubocop:disable Style/GlobalVars
    end
  end

  def test_a_missing_app_exits_2
    assert_equal 2, command('preflight', '--app', '/nonexistent/app.rb')
  end

  # --- server facts -------------------------------------------------------

  def test_server_section_reports_the_backend
    redis = run_doc('preflight').dig('sections', 'redis')

    assert_equal 'redis', redis['backend']
    assert_match(/\A\d+\./, redis['version'])
  end

  def test_an_evicting_policy_and_an_old_server_are_findings
    report = Wurk::Preflight::Report.new('preflight')
    checks = checks_for(report)
    checks.send(:eviction, 'allkeys-lru', 'redis')
    checks.send(:eviction, nil, 'other')
    checks.send(:version_check, 'redis', '6.2.0')
    checks.send(:topology, { 'cluster_enabled' => '1' })
    checks.send(:dragonfly_memory, { 'used_memory' => '90', 'maxmemory' => '100' })
    checks.send(:dragonfly_memory, { 'used_memory' => '10', 'maxmemory' => '100' })

    assert_equal %w[eviction eviction_unknown redis_version redis_cluster dragonfly_memory dragonfly],
                 report.findings.map(&:code)
  end

  def test_mixed_fleet_is_a_finding
    beat('stock:1:aaaaaaaaaaaa', cores: false, version: '7.3.10')
    beat('wurk:2:bbbbbbbbbbbb')

    assert_includes warnings(run_doc('preflight')), 'mixed_fleet'
  end

  # --- read-only proofs ---------------------------------------------------

  def test_the_reader_refuses_anything_but_a_read
    r = reader
    %w[LLEN SET DEL FLUSHDB EVAL EVALSHA LMOVE RPOP HSET CONFIG].each do |command|
      assert_raises(Wurk::Preflight::Reader::Forbidden, command) { r.call(command, 'k') }
      assert_raises(Wurk::Preflight::Reader::Forbidden, command) { r.pipeline([[command, 'k']]) }
    end
  ensure
    r&.close
  end

  def test_preflight_and_verify_write_nothing_and_send_no_llen
    url = start_private_server
    seed_everything(url)
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config.redis = { url: url }
    before = dump(url)
    changes = dirty(url)
    @private.call('CONFIG', 'RESETSTAT')

    Wurk::Preflight.run(config, pause: 0)
    Wurk::Preflight::Verify.run(config, pause: 0)

    stats = @private.call('INFO', 'commandstats')
    sent = stats.scan(/cmdstat_([a-z|]+):/).flatten - %w[info config|resetstat config hello client client|setinfo]

    assert_empty sent - %w[dbsize scan type exists get hget hmget hgetall smembers lrange lindex zrange zcard],
                 "preflight sent: #{sent}"
    refute_includes sent, 'llen'
    assert_equal changes, dirty(url), 'rdb_changes_since_last_save moved'
    assert_equal before, dump(url)
  end

  def test_preflight_runs_under_a_read_only_acl_user
    url = start_private_server
    seed_everything(url)
    @private.call('ACL', 'SETUSER', 'ro', 'on', '>pw', '~*', '&*', '+@read', '+info', '+client', '+hello', '+ping',
                  '+scan')
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config.redis = { url: url.sub('redis://', 'redis://ro:pw@') }

    assert_equal 'preflight', Wurk::Preflight.run(config, pause: 0).to_h['command']
  end

  def test_the_wurk_executable_dispatches_both_commands
    %w[preflight verify].each do |name|
      out, status = Open3.capture2e({ 'REDIS_URL' => Wurk::Test.redis_url }.compact, ::RbConfig.ruby,
                                    EXE, name, '--json', '--pause-ms', '0')

      assert_includes [0, 1], status.exitstatus, out
      assert_equal name, JSON.parse(out)['command']
    end
  end

  # --- verify -------------------------------------------------------------

  def test_verify_flags_an_unconsumed_queue_a_dead_leader_and_no_processes
    @redis.call('SADD', 'queues', 'orphaned')
    @redis.call('LPUSH', 'queue:orphaned', job('j'))
    @redis.call('SET', 'dear-leader', 'old:1:aaaaaaaaaaaa')

    doc = run_doc('verify')

    assert_includes warnings(doc), 'no_processes'
    assert_includes warnings(doc), 'queue_unconsumed'
    assert_includes warnings(doc), 'leader_not_live_wurk'
  end

  def test_verify_is_clean_on_a_healthy_fleet
    identity = 'h:1:aaaaaaaaaaaa'
    beat(identity, queues: %w[a b])
    @redis.call('SADD', 'queues', 'a', 'b', 'empty')
    @redis.call('LPUSH', 'queue:a', job('j'))
    @redis.call('LPUSH', 'queue:a|h|1|aaaaaaaaaaaa|0', job('k'))
    @redis.call('SET', 'dear-leader', identity)
    loop_row('lid1', '*/5 * * * *', tz: 'UTC')

    doc = run_doc('verify')

    assert_empty warnings(doc), @out.string
    assert_equal 'clean', doc['status']
    assert_equal 1, doc.dig('sections', 'cron', 'loops')
  end

  def test_verify_flags_no_leader_and_a_stock_process
    beat('stock:1:aaaaaaaaaaaa', cores: false, version: '7.3.10')

    assert_includes warnings(run_doc('verify')), 'no_leader'
    assert_includes warnings(run_doc('verify')), 'non_wurk_process'
  end

  def test_verify_leaves_a_paused_queue_alone
    @redis.call('SADD', 'queues', 'held')
    @redis.call('SADD', 'paused', 'held')
    @redis.call('LPUSH', 'queue:held', job('j'))

    refute_includes warnings(run_doc('verify')), 'queue_unconsumed'
  end

  def test_verify_flags_too_many_live_owned_lists_and_bad_ones
    beat('h:1:aaaaaaaaaaaa', queues: %w[a])
    @redis.call('LPUSH', 'queue:a|h|1|aaaaaaaaaaaa|0', job('j'))
    @redis.call('LPUSH', 'queue:b|h|1|aaaaaaaaaaaa|0', job('k'))
    @redis.call('LPUSH', 'queue:c|gone|9|bbbbbbbbbbbb|0', job('l'))
    @redis.call('LPUSH', 'queue:sq|h:1:x|a', job('m'))

    found = warnings(run_doc('verify'))

    assert_includes found, 'private_list_count'
    assert_includes found, 'reclaimable_lists'
    assert_includes found, 'unparseable_lists'
  end

  def test_verify_flags_a_loop_with_no_next_fire_and_ignores_a_paused_one
    loop_row('bad', 'not a cron')
    loop_row('held', 'not a cron', paused: '1')

    doc = run_doc('verify')

    assert_equal ['bad'], doc.dig('sections', 'cron', 'without_next_fire')
    assert_includes warnings(doc), 'loop_no_next_fire'
  end

  def test_verify_flags_cron_entries_nothing_will_fire
    skip 'sidekiq-cron is in this bundle' if ::Gem.loaded_specs.key?('sidekiq-cron')
    @redis.call('HSET', 'cron_job:default:nightly', 'cron', '0 3 * * *')

    assert_includes warnings(run_doc('verify')), 'cron_not_moved'
  end

  def test_verify_reads_only_unless_a_canary_is_named
    beat('h:1:aaaaaaaaaaaa', queues: %w[a])

    run_doc('verify')

    assert_equal 0, @redis.call('EXISTS', 'queue:a')

    doc = run_doc('verify', '--canary', 'CanaryJob')
    pushed = JSON.parse(@redis.call('LINDEX', 'queue:a', 0))

    assert_equal %w[CanaryJob a], [pushed['class'], pushed['args'].first]
    assert_equal pushed['jid'], doc.dig('sections', 'canary', 'pushed', 'a')
  end

  private

  def rails_env(marker)
    { 'RAILS_ENV' => 'production', 'WURK_EMBED' => '1', 'WURK_COUNT' => '1', 'WURK_DISABLED' => nil,
      'MARKER' => marker, 'SECRET_KEY_BASE' => 'x' * 64 }
  end

  def rails_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, 'config'))
    marker = File.join(dir, 'marker.json')
    File.write(File.join(dir, 'config/environment.rb'), <<~RUBY)
      disabled_at_load = ENV['WURK_DISABLED']
      require 'json'
      require 'logger'
      require 'rails'
      require 'action_controller/railtie'
      require 'wurk/rails'
      class PreflightFixtureApp < Rails::Application
        config.root = #{dir.inspect}
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.secret_key_base = ENV['SECRET_KEY_BASE']
      end
      Sidekiq.configure_server { |c| c.redis = { url: ENV.fetch('APP_REDIS_URL') } }
      skip = Wurk::RailsBoot.send(:skip_boot?)
      File.write(ENV.fetch('MARKER'), JSON.generate('disabled_at_load' => disabled_at_load, 'skip_boot' => skip, 'children' => []))
      Rails.application.initialize!
      children = `pgrep -P \#{Process.pid}`.split
      File.write(ENV.fetch('MARKER'), JSON.generate('disabled_at_load' => disabled_at_load, 'skip_boot' => skip, 'children' => children))
    RUBY
    marker
  end

  def command(*argv)
    @out = StringIO.new
    Wurk::Preflight::Command.run(argv, config: @config, out: @out, err: @err)
  end

  def run_doc(name, *)
    command(name, '--json', '--pause-ms', '0', *)
    JSON.parse(@out.string)
  end

  def codes(doc) = doc['findings'].map { |f| f['code'] }
  def warnings(doc) = doc['findings'].select { |f| f['severity'] == 'warning' }.map { |f| f['code'] }
  def reader = Wurk::Preflight::Reader.new(@config)

  def job(jid, extra = {})
    JSON.generate({ 'class' => 'X', 'jid' => jid, 'queue' => 'q', 'args' => [] }.merge(extra))
  end

  def envelope = { '__wurk_enc__' => true, 'v' => 1, 'iv' => 'a', 'ct' => 'b', 'tag' => 'c' }

  def beat(identity, cores: true, version: Wurk::VERSION, queues: %w[q])
    info = { 'identity' => identity, 'version' => version, 'queues' => queues }
    info['cores'] = 4 if cores
    @redis.call('SADD', 'processes', identity)
    @redis.call('HSET', identity, 'info', JSON.generate(info), 'quiet', 'false')
  end

  def loop_row(lid, schedule, tz: '', paused: '0')
    @redis.call('SADD', 'periodic', lid)
    @redis.call('HSET', "loops:#{lid}", 'schedule', schedule, 'klass', 'X', 'options', '{}', 'tz', tz, 'paused', paused)
  end

  def checks_for(report)
    Wurk::Preflight::Checks.new(reader: nil, report: report, keyspace: nil, owners: nil, sample: 1)
  end

  def seed_everything(url)
    client = RedisClient.config(url: url).new_client
    client.call('SADD', 'queues', 'q')
    client.call('LPUSH', 'queue:q', job('a', 'created_at' => 1_793_625_000_500, 'encrypt' => true, 'args' => ['x']))
    client.call('LPUSH', 'queue:q|gone|1|aaaaaaaaaaaa|0', job('b'))
    client.call('LPUSH', 'queue:sq|odd|q', job('c'))
    client.call('ZADD', 'retry', 1, job('d', 'retry_for' => 5))
    client.call('ZADD', 'dead', 1, job('e'))
    client.call('ZADD', 'schedule', 1, job('f'))
    client.call('HSET', 'b-x', 'pending', '1')
    client.call('SET', "unique:#{'a' * 40}", 'j')
    client.call('SET', "uniquejobs:#{'c' * 32}", 'j')
    client.call('SADD', 'processes', 'h:1:aaaaaaaaaaaa')
    client.call('HSET', 'h:1:aaaaaaaaaaaa', 'info', JSON.generate('version' => '1', 'cores' => 1, 'queues' => ['q']))
    client.call('SADD', 'periodic', 'lid')
    client.call('HSET', 'loops:lid', 'schedule', '* * * * *', 'klass', 'X', 'tz', '', 'paused', '0')
    client.call('SET', 'dear-leader', 'h:1:aaaaaaaaaaaa')
    client.close
  end

  def dump(url)
    client = RedisClient.config(url: url).new_client
    client.call('KEYS', '*').sort.to_h { |key| [key, client.call('DUMP', key)] }
  ensure
    client&.close
  end

  def dirty(url)
    client = RedisClient.config(url: url).new_client
    client.call('INFO', 'persistence')[/rdb_changes_since_last_save:(\d+)/, 1].to_i
  ensure
    client&.close
  end

  def start_private_server
    skip 'needs a redis-server binary' unless system('command -v redis-server > /dev/null 2>&1')

    @dir = Dir.mktmpdir('wurk-preflight')
    port = free_port
    @server = Process.spawn('redis-server', '--port', port.to_s, '--bind', '127.0.0.1', '--save', '', '--dir', @dir,
                            out: IO::NULL, err: IO::NULL)
    url = "redis://127.0.0.1:#{port}/0"
    @private = RedisClient.config(url: url, timeout: 5).new_client
    wait_until(timeout: 10) do
      @private.call('PING') == 'PONG'
    rescue RedisClient::Error
      false
    end
    url
  end

  def stop_private_server
    @private&.close
    return unless @server

    Process.kill('TERM', @server)
    Process.wait(@server)
    FileUtils.remove_entry(@dir) if @dir
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def wait_until(timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk 'condition not met' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end
end
