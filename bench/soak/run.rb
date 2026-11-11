# frozen_string_literal: true

# Soak + chaos with a jid ledger (plan 101/12 T1, 102/09 T1). Boots a private
# redis-server (AOF, appendfsync always) and `exe/wurkswarm`, pushes a mixed
# workload (plain, scheduled, retry, unique, limiter, iterable, nested batches
# with :success callbacks, status-tracked, a cron loop), injects faults
# (bench/soak/chaos.rb), then drains and judges the ledger:
#
#   every pushed jid completed at least once (or sits in the dead set);
#   every extra completion falls in a documented at-least-once window
#   (docs/reliability.md) or is listed as unattributed;
#   every nested batch ran :success once, child before parent;
#   no job ran that nobody pushed.
#
# Exit 0 = balanced, 1 = not, 2 = the harness itself broke. Advisory memory and
# key-count slopes ride along; they never set the exit code.
#
#   ruby -Ilib bench/soak/run.rb                     # short: ~2.5 min load + drain
#   SOAK_MODE=long ruby -Ilib bench/soak/run.rb      # 1h, CI nightly
#   SOAK_MODE=long SOAK_DURATION=86400 ...           # the 24h proof run
#   SOAK_LOSSY=50 ruby -Ilib bench/soak/run.rb       # self-test: must exit 1
#
# Knobs (env): SOAK_DURATION s, SOAK_RATE jobs/s, SOAK_COUNT children,
# SOAK_CONCURRENCY threads, SOAK_CHAOS ops csv or "none", SOAK_CHAOS_INTERVAL s,
# SOAK_SAMPLE_INTERVAL s, SOAK_DRAIN_TIMEOUT s, SOAK_SEED, SOAK_OUT dir,
# SOAK_APP=dummy (boot test/dummy in the workers). Never touches a Redis it did
# not start; output lands in SOAK_OUT (default tmp/soak/<timestamp>).

require 'fileutils'
require 'json'
require 'logger'
require_relative 'redis_server'
require_relative 'sampler'
require_relative 'swarm_process'
require_relative 'chaos'
require_relative 'ledger'
require_relative 'producer'
require_relative 'report'

module WurkSoak
  class Run
    ALL_OPS = Chaos::OPS.join(',')
    MODES = {
      'short' => { duration: 150, rate: 100, chaos_interval: 12, sample_interval: 5, drain_timeout: 300 },
      'long' => { duration: 3600, rate: 100, chaos_interval: 60, sample_interval: 300, drain_timeout: 600 }
    }.freeze

    def initialize(env = ENV)
      mode = MODES.fetch(env.fetch('SOAK_MODE', 'short')) { raise ArgumentError, "SOAK_MODE: #{MODES.keys.join('|')}" }
      @opts = {
        duration: Float(env.fetch('SOAK_DURATION', mode[:duration])),
        rate: Float(env.fetch('SOAK_RATE', mode[:rate])),
        count: Integer(env.fetch('SOAK_COUNT', '4')),
        concurrency: Integer(env.fetch('SOAK_CONCURRENCY', '5')),
        chaos: env.fetch('SOAK_CHAOS', ALL_OPS).split(',').map(&:strip) - %w[none],
        chaos_interval: Float(env.fetch('SOAK_CHAOS_INTERVAL', mode[:chaos_interval])),
        sample_interval: Float(env.fetch('SOAK_SAMPLE_INTERVAL', mode[:sample_interval])),
        drain_timeout: Float(env.fetch('SOAK_DRAIN_TIMEOUT', mode[:drain_timeout])),
        seed: Integer(env.fetch('SOAK_SEED', Random.new_seed % 1_000_000)),
        lossy: Integer(env.fetch('SOAK_LOSSY', '0')),
        app: env.fetch('SOAK_APP', 'minimal')
      }
      @out = File.expand_path(env.fetch('SOAK_OUT') { "tmp/soak/#{Time.now.strftime('%Y%m%d-%H%M%S')}" })
      @samples = []
    end

    def call
      boot
      load_phase
      drained = drain
      finish(drained)
    ensure
      teardown
    end

    private

    def boot
      FileUtils.mkdir_p(@out)
      ENV['SOAK_LEDGER'] = @ledger = File.join(@out, 'ledger.tsv')
      @redis = RedisServer.new(dir: File.join(@out, 'redis')).start
      ENV['REDIS_URL'] = @redis.url
      require 'wurk'
      Wurk.configuration.logger = Logger.new(File.join(@out, 'producer.log'))
      require_relative 'app'
      @swarm = SwarmProcess.new(env: swarm_env, log: File.join(@out, 'swarm.log'),
                                require_path: File.expand_path('app.rb', __dir__), concurrency: @opts[:concurrency])
      @swarm.start
      wait_for { live_processes >= @opts[:count] } or raise "swarm never reported #{@opts[:count]} processes"
      log "booted: redis :#{@redis.port}, swarm #{@swarm.pid}, out #{@out}, seed #{@opts[:seed]}"
    end

    def swarm_env
      { 'REDIS_URL' => @redis.url, 'SOAK_LEDGER' => @ledger, 'WURK_COUNT' => @opts[:count].to_s,
        'SOAK_CRON' => '1', 'SOAK_LOSSY' => @opts[:lossy].to_s, 'SOAK_APP' => @opts[:app] }
    end

    def load_phase
      rng = Random.new(@opts[:seed])
      @producer = Producer.new(rate: @opts[:rate], rng: Random.new(rng.rand(1 << 30)))
      @chaos = Chaos.new(swarm: @swarm, redis: @redis, ops: @opts[:chaos], interval: @opts[:chaos_interval],
                         rng: Random.new(rng.rand(1 << 30)))
      @t0 = monotonic
      threads = [Thread.new { @producer.run }, Thread.new { @chaos.run }, Thread.new { sample_loop }]
      threads.first(2).each { |t| t.report_on_exception = true }
      sleep 1 until monotonic - @t0 >= @opts[:duration]
      @producer.stop!
      @chaos.stop!
      threads.first(2).each(&:join)
      @sampler = threads.last
      log "load done: #{@producer.pushed} pushed in #{(monotonic - @t0).round}s"
    end

    # Waits for the ledger to account for every push and batch.
    def drain
      book = Ledger::Book.new(@ledger)
      deadline = monotonic + @opts[:drain_timeout]
      loop do
        book.ingest!
        return true if book.pending_jids.empty? && book.pending_batches.empty?
        return false if monotonic > deadline

        sleep 2
      end
    end

    def finish(drained)
      @stop_sampling = true
      @sampler&.join
      dead = dead_set
      take_sample
      @swarm.stop
      book = Ledger::Book.new(@ledger).ingest!
      verdict = Ledger::Verdict.new(book, dead: dead).to_h
      report = Report.new(opts: @opts, verdict: verdict, samples: @samples, drained: drained).to_h
      File.write(File.join(@out, 'report.json'), JSON.pretty_generate(report))
      puts Report.summary(report)
      puts "report: #{File.join(@out, 'report.json')}"
      verdict[:balanced] ? 0 : 1
    end

    def dead_set
      c = @redis.client
      c.call('ZRANGE', 'dead', 0, -1).to_h do |payload|
        job = JSON.parse(payload)
        [job['jid'], job['error_message']]
      end
    ensure
      c&.close
    end

    def sample_loop
      until @stop_sampling
        take_sample
        deadline = monotonic + @opts[:sample_interval]
        sleep 0.5 until @stop_sampling || monotonic >= deadline
      end
    end

    def take_sample
      kids = @swarm.children
      @samples << { t: (monotonic - @t0).round(1), parent: Sampler.memory(@swarm.pid.to_i),
                    children: kids.to_h { |pid| [pid, Sampler.memory(pid)] }.compact, redis: redis_sample }
    end

    def redis_sample
      c = @redis.client
      Sampler.redis(c)
    rescue RedisClient::Error
      nil
    ensure
      c&.close
    end

    def live_processes
      c = @redis.client
      c.call('SCARD', 'processes')
    rescue RedisClient::Error
      0
    ensure
      c&.close
    end

    def teardown
      @producer&.stop!
      @chaos&.stop!
      @stop_sampling = true
      @swarm&.stop
      @redis&.stop
    end

    def wait_for(timeout = 60)
      deadline = monotonic + timeout
      until monotonic > deadline
        return true if yield

        sleep 0.2
      end
      false
    end

    def log(msg) = warn("[soak #{Time.now.strftime('%H:%M:%S')}] #{msg}")

    def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit WurkSoak::Run.new.call
  rescue StandardError => e
    warn "soak harness failed: #{e.class}: #{e.message}"
    warn e.backtrace.first(10).join("\n")
    exit 2
  end
end
