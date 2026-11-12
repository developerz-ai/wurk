# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../bench/soak/ledger'
require_relative '../../bench/soak/redis_server'
require_relative '../../bench/soak/sampler'
require_relative '../../bench/vs_sidekiq/child_env'

# A rolling cutover, for real (plan 101/12 T2): stock Sidekiq, installed from
# bench/vs_sidekiq/Gemfile and run in its own process under its own bundle, next
# to `exe/wurkswarm` from this tree, both on one private redis-server. Every
# push, attempt and completion goes to the jid ledger (bench/soak/ledger.rb)
# with the engine that wrote it, and the verdict comes from there.
#
# Needs the isolated Sidekiq bundle (`BUNDLE_GEMFILE=bench/vs_sidekiq/Gemfile
# bundle install`) and a redis-server binary; skips without either. The
# `mixed fleet` job in .github/workflows/test.yml installs both and sets
# WURK_REQUIRE_MIXED_FLEET, which turns the skip into a failure.
class MixedFleetTest < Wurk::Test::UnitCase
  ROOT = File.expand_path('../..', __dir__)
  JOB = File.join(__dir__, 'mixed_fleet', 'job.rb')
  CLIENT = File.join(__dir__, 'mixed_fleet', 'client.rb')
  SIDEKIQ_GEMFILE = File.join(ROOT, 'bench', 'vs_sidekiq', 'Gemfile')
  WURKSWARM = File.join(ROOT, 'exe', 'wurkswarm')
  WURK_COUNT = 2
  CONCURRENCY = '5'
  DEADLINE = 90
  HOLDS = 4
  # MIXED_FLEET_RELEASE_KEY in mixed_fleet/job.rb, which this process does not
  # load: it would configure the suite's own Wurk.
  RELEASE_KEY = 'mixed-fleet:release'

  class << self
    def sidekiq_bundle_installed?
      return @sidekiq_bundle_installed if defined?(@sidekiq_bundle_installed)

      @sidekiq_bundle_installed =
        system(sidekiq_bundle_env, 'bundle', 'check', chdir: ROOT, out: File::NULL, err: File::NULL)
    end

    # Every channel `bundle exec` leaks into a child, closed, so BUNDLE_GEMFILE
    # alone decides which "sidekiq" loads (bench/vs_sidekiq/child_env.rb).
    def sidekiq_bundle_env
      BenchVsSidekiq::ChildEnv::LEAKS.to_h { |key| [key, nil] }.merge('BUNDLE_GEMFILE' => SIDEKIQ_GEMFILE)
    end
  end

  def setup
    super
    preconditions!
    @dir = Dir.mktmpdir('wurk-mixed-fleet')
    @server = WurkSoak::RedisServer.new(dir: File.join(@dir, 'redis'), aof: false).start
    @redis = @server.client
    @ledger = File.join(@dir, 'ledger.tsv')
    @book = WurkSoak::Ledger::Book.new(@ledger)
    @live = {}
  end

  def teardown
    @live&.each_key { |pid| kill_tree(pid) }
    @redis&.close
    @server&.stop
    FileUtils.rm_rf(@dir) if @dir
  ensure
    super
  end

  # (a) + (d): both fleets fetch from `shared` while both clients push to it.
  # `to_sidekiq` and `to_wurk` each have one consumer, so a Wurk-written job
  # provably runs on Sidekiq and a Sidekiq-written one on Wurk.
  def test_both_fleets_run_every_job_either_client_pushes_during_the_overlap
    sidekiq = start_sidekiq('shared', 'to_sidekiq')
    swarm = start_swarm('shared', 'to_wurk')
    await_sidekiq(sidekiq)
    await_swarm(swarm)

    wurk_push, sidekiq_push = [
      Thread.new { client(:wurk, 'push', 'shared:200:plain', 'to_sidekiq:40:cross', 'shared:40:scheduled:1') },
      Thread.new { client(:sidekiq, 'push', 'shared:200:plain', 'to_wurk:40:cross', 'shared:40:scheduled:1') }
    ].map(&:value)
    jids = wurk_push['jids'] + sidekiq_push['jids']
    await_done(jids)
    stop(sidekiq)
    stop(swarm)

    verdict = balanced_verdict(560)

    assert_equal 560, jids.uniq.size
    assert(@book.dones.values.all? { |dones| dones.size == 1 }, "a job completed twice: #{verdict[:duplicates]}")
    %w[wurk sidekiq].each do |client|
      assert_equal %w[sidekiq wurk], runners(pushed_by: client, kind: 'plain').keys.sort,
                   "#{client}-written jobs on `shared` ran on one engine only"
    end
    assert_equal({ 'sidekiq' => 40 }, runners(pushed_by: 'wurk', kind: 'cross'), 'Wurk-written jobs on Sidekiq')
    assert_equal({ 'wurk' => 40 }, runners(pushed_by: 'sidekiq', kind: 'cross'), 'Sidekiq-written jobs on Wurk')
    assert_empty private_lists
    assert_equal [0, 0, 0, 0], %w[queue:shared queue:to_sidekiq queue:to_wurk].map { |q| @redis.call('LLEN', q) } +
                               [@redis.call('ZCARD', 'schedule')]
  end

  # (b): a Sidekiq -> Wurk handoff. Sidekiq alone promotes the schedule entries
  # Wurk's client wrote; then Wurk starts, Sidekiq stops, and Wurk alone
  # promotes the ones Sidekiq's client wrote.
  def test_each_side_promotes_the_other_sides_scheduled_jobs_across_a_handoff
    sidekiq = start_sidekiq('shared')
    await_sidekiq(sidekiq)
    from_wurk = client(:wurk, 'push', 'shared:30:scheduled:1')['jids']
    await_done(from_wurk)

    swarm = start_swarm('shared')
    await_swarm(swarm)
    stop(sidekiq)
    from_sidekiq = client(:sidekiq, 'push', 'shared:30:scheduled:1')['jids']
    await_done(from_sidekiq)
    stop(swarm)

    balanced_verdict(60)

    assert_equal({ 'sidekiq' => 30 }, runners(pushed_by: 'wurk', kind: 'scheduled'))
    assert_equal({ 'wurk' => 30 }, runners(pushed_by: 'sidekiq', kind: 'scheduled'))
  end

  # (c), graceful: a Wurk -> Sidekiq handoff (a rollback) while Wurk has jobs in
  # flight past its shutdown timeout. Wurk's stop moves them from its private
  # lists back to the public queue, where Sidekiq runs them.
  def test_a_stopped_wurk_hands_its_in_flight_jobs_to_sidekiq
    swarm = start_swarm('shared', timeout: '1')
    await_swarm(swarm)
    holds = client(:wurk, 'push', "shared:#{HOLDS}:hold")['jids']
    await_running(holds, 'wurk')

    sidekiq = start_sidekiq('shared')
    await_sidekiq(sidekiq)
    stop(swarm)

    assert_empty private_lists, 'Wurk stopped with jobs still in its private lists'
    @redis.call('SET', RELEASE_KEY, '1')
    await_done(holds)
    stop(sidekiq)

    balanced_verdict(HOLDS)

    assert_equal({ 'sidekiq' => HOLDS }, runners(pushed_by: 'wurk', kind: 'hold'))
  end

  # (c), hard: the whole Wurk host dies at once (parent and children SIGKILLed,
  # as on a pod OOM kill or node loss). Its in-flight jobs stay in its private
  # lists, and stock Sidekiq, fetching from the same queue, leaves them there:
  # it has no reclaim for any private list. Only a Wurk process's reaper
  # returns them (docs/reliability.md).
  def test_sidekiq_leaves_a_killed_wurk_hosts_private_lists_alone
    swarm = start_swarm('shared')
    await_swarm(swarm)
    holds = client(:wurk, 'push', "shared:#{HOLDS}:hold")['jids']
    await_running(holds, 'wurk')
    kill_host(swarm)

    assert_equal holds.sort, stranded_jids.sort

    sidekiq = start_sidekiq('shared')
    await_sidekiq(sidekiq)
    @redis.call('SET', RELEASE_KEY, '1')
    probe = client(:sidekiq, 'push', 'shared:1:plain')['jids']
    await_done(probe)

    assert_equal({ 'sidekiq' => 1 }, runners(pushed_by: 'sidekiq', kind: 'plain'))
    assert_equal holds.sort, stranded_jids.sort, 'Sidekiq moved a dead Wurk process\'s private list'
    assert(holds.none? { |jid| @book.dones.key?(jid) })
  end

  # (d): each side's API reads the other's payload timestamps. Sidekiq 8 and
  # Wurk both write epoch milliseconds; a seconds/milliseconds mix-up shows as
  # dates in the year 58807 or a negative latency.
  def test_each_side_reads_the_other_sides_payload_timestamps
    before = Time.now.to_f
    client(:wurk, 'push', 'from_wurk:1:plain', 'from_wurk:1:scheduled:3600')
    client(:sidekiq, 'push', 'from_sidekiq:1:plain', 'from_sidekiq:1:scheduled:3600')
    after = Time.now.to_f

    { sidekiq: client(:sidekiq, 'inspect', 'from_wurk'), wurk: client(:wurk, 'inspect', 'from_sidekiq') }
      .each do |reader, seen|
        job = seen['jobs'].first
        entry = seen['scheduled'].first

        assert_equal [1, 1], [seen['jobs'].size, seen['scheduled'].size], reader
        assert_millis job['raw_created_at'], reader
        assert_millis entry['raw_created_at'], reader
        assert_in_window job['created_at'], before, after, "#{reader} created_at"
        assert_in_window job['enqueued_at'], before, after, "#{reader} enqueued_at"
        assert_in_window entry['created_at'], before, after, "#{reader} scheduled created_at"
        assert_in_window entry['at'], before + 3600, after + 3600, "#{reader} scheduled at"
        assert_operator seen['latency'], :>=, 0, "#{reader} latency"
        assert_operator seen['latency'], :<=, Time.now.to_f - before + 1, "#{reader} latency"
      end
  end

  private

  def preconditions!
    missing = []
    missing << 'a redis-server binary on PATH' unless system('command -v redis-server > /dev/null 2>&1')
    unless self.class.sidekiq_bundle_installed?
      missing << 'the stock Sidekiq bundle (BUNDLE_GEMFILE=bench/vs_sidekiq/Gemfile bundle install)'
    end
    return if missing.empty?

    flunk "mixed fleet needs #{missing.join(' and ')}" if ENV['WURK_REQUIRE_MIXED_FLEET']
    skip "mixed fleet needs #{missing.join(' and ')}"
  end

  # The suite's COVERAGE would make every child write a resultset.
  def common_env = { 'REDIS_URL' => @server.url, 'SOAK_LEDGER' => @ledger, 'COVERAGE' => nil }

  def env_for(side)
    side == :sidekiq ? self.class.sidekiq_bundle_env.merge(common_env) : common_env
  end

  def ruby_for(side)
    side == :sidekiq ? %w[bundle exec ruby] : [RbConfig.ruby, *('-rbundler/setup' if defined?(::Bundler))]
  end

  def start_sidekiq(*queues)
    log = File.join(@dir, 'sidekiq.log')
    pid = Process.spawn(env_for(:sidekiq), 'bundle', 'exec', 'sidekiq', '-r', JOB, *queues.flat_map { ['-q', _1] },
                        '-c', CONCURRENCY, '-t', '5', chdir: ROOT, %i[out err] => [log, 'a'])
    @live[pid] = log
    pid
  end

  def start_swarm(*queues, timeout: '5')
    log = File.join(@dir, 'wurk.log')
    pid = Process.spawn(env_for(:wurk).merge('WURK_COUNT' => WURK_COUNT.to_s), *ruby_for(:wurk), WURKSWARM,
                        '-r', JOB, *queues.flat_map { ['-q', _1] }, '-c', CONCURRENCY, '-t', timeout,
                        chdir: ROOT, %i[out err] => [log, 'a'])
    @live[pid] = log
    pid
  end

  # One JSON line back from test/integration/mixed_fleet/client.rb, run under
  # the side's own bundle. The Sidekiq side must really be Sidekiq 8.
  def client(side, *args)
    out, err, status = Open3.capture3(env_for(side), *ruby_for(side), CLIENT, *args, chdir: ROOT)

    assert_predicate status, :success?, "#{side} client #{args.join(' ')} failed:\n#{err}"
    result = JSON.parse(out.lines.last)

    assert_equal side.to_s, result['engine'], "the #{side} client loaded the wrong engine"
    assert_match(/\A8\./, result['version'], 'the Sidekiq side is not Sidekiq 8') if side == :sidekiq
    result
  end

  # pid => the `info` each live process heartbeats.
  def heartbeats
    @redis.call('SMEMBERS', 'processes').filter_map do |identity|
      info = @redis.call('HGET', identity, 'info')
      JSON.parse(info).then { [_1['pid'], _1] } if info
    end.to_h
  end

  def heartbeat_pids = heartbeats.keys

  def await_sidekiq(pid)
    await("Sidekiq #{pid} heartbeat") { heartbeat_pids.include?(pid) }

    assert_match(/\A8\./, heartbeats.fetch(pid)['version'], 'the Sidekiq worker is not Sidekiq 8')
  end

  def await_swarm(pid)
    await("#{WURK_COUNT} wurkswarm children heartbeating") do
      (heartbeat_pids & WurkSoak::Sampler.children(pid)).size == WURK_COUNT
    end
  end

  def await_done(jids)
    await("#{jids.size} completions") { jids.all? { |jid| @book.ingest!.dones.key?(jid) } }
  end

  def await_running(jids, engine)
    await("#{jids.size} jobs running on #{engine}") do
      @book.ingest!
      jids.all? { |jid| @book.runs[jid].any? { |run| run.extra == engine } }
    end
  end

  def await(what, timeout: DEADLINE)
    deadline = monotonic + timeout
    until yield
      @live.each do |pid, log|
        next unless Process.wait(pid, Process::WNOHANG)

        flunk "#{what}: #{File.basename(log, '.log')} #{pid} exited early\n#{tail(log)}"
      end
      flunk "#{what}: not within #{timeout}s\n#{@live.values.uniq.map { tail(_1) }.join}" if monotonic > deadline
      sleep 0.05
    end
  end

  # TERM, then wait for the drain. The swarm parent relays TERM to its children
  # and exits after they do.
  def stop(pid)
    log = @live.fetch(pid)
    Process.kill('TERM', pid)
    deadline = monotonic + 30
    until Process.wait(pid, Process::WNOHANG)
      flunk "#{pid} did not stop within 30s\n#{tail(log)}" if monotonic > deadline
      sleep 0.05
    end
    @live.delete(pid)
  end

  # SIGSTOP first, so the parent cannot reap a child and drain its lists, then
  # SIGKILL children and parent: nothing gets a chance to clean up.
  def kill_host(pid)
    Process.kill('STOP', pid)
    kill_tree(pid)
    @live.delete(pid)
  end

  def kill_tree(pid)
    [*WurkSoak::Sampler.children(pid), pid].each do |victim|
      Process.kill('KILL', victim)
    rescue Errno::ESRCH
      nil
    end
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  def private_lists = @redis.call('KEYS', 'queue:*|*')

  def stranded_jids
    private_lists.flat_map { |list| @redis.call('LRANGE', list, 0, -1) }.map { JSON.parse(_1)['jid'] }
  end

  # The ledger's verdict, which must be balanced: nothing lost, no duplicate,
  # no run nobody pushed. No chaos runs here, so no window excuses a duplicate.
  def balanced_verdict(pushed)
    verdict = WurkSoak::Ledger::Verdict.new(@book.ingest!).to_h

    assert_equal pushed, verdict[:pushed]
    assert_empty verdict[:lost], 'lost jobs'
    assert_empty verdict[:duplicates][:by_window], 'duplicate completions'
    assert_empty verdict[:duplicates][:unattributed], 'duplicate completions'
    assert_empty verdict[:unledgered], 'jobs nobody pushed'
    assert verdict[:balanced]
    verdict
  end

  # engine => completions, for the jobs of `kind` one engine's client pushed.
  def runners(pushed_by:, kind:)
    jids = @book.pushes.values.select { |push| push.extra == pushed_by && push.kind == kind }.map(&:id)
    jids.flat_map { |jid| @book.dones[jid].map(&:extra) }.tally
  end

  def assert_millis(value, reader)
    assert_kind_of Integer, value, "#{reader}: raw timestamp"
    assert_operator value, :>, 10**12, "#{reader}: raw timestamp is not epoch milliseconds"
  end

  def assert_in_window(value, from, upto, what)
    assert_operator value, :>=, from - 1, what
    assert_operator value, :<=, upto + 1, what
  end

  def tail(log) = File.exist?(log) ? "--- #{File.basename(log)}\n#{File.readlines(log).last(30).join}" : ''

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
