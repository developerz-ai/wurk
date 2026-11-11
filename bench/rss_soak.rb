# frozen_string_literal: true

# Per-child memory of a real `wurkswarm` over job count (plan 101/08 M0).
# Boots a private redis-server and WURK_COUNT children (default 4) running
# bench/soak/app.rb on top of test/dummy, pushes RSS_JOBS jobs in RSS_STEP
# slices, and after each slice reads every child's /proc/<pid>/smaps_rollup:
#
#   Rss, Pss, Private_Dirty, shared ratio (Shared_* / Rss), plus Redis
#   used_memory and DBSIZE,
#
# then fits a least-squares slope per child, in kB per 10k jobs. A flat Pss
# slope means no per-job growth; a falling shared ratio is copy-on-write
# being undone. Advisory, Linux only, never part of `rake bench`: it boots a
# swarm and its numbers move with the host.
#
#   ruby -Ilib bench/rss_soak.rb
#   RSS_FEATURES=status,unique,limiter ruby -Ilib bench/rss_soak.rb   # feature mix
#   WURK_PRELOAD_APP=1 MALLOC_ARENA_MAX=2 ruby -Ilib bench/rss_soak.rb
#   LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 ruby -Ilib bench/rss_soak.rb
#
# Env: RSS_JOBS (100000), RSS_STEP (10000), WURK_COUNT (4), RSS_CONCURRENCY (5),
# RSS_APP (dummy | minimal), RSS_FEATURES (csv of plain,status,unique,limiter;
# default plain), RSS_OUT (JSON path; default tmp/rss/<timestamp>.json).
# Allocator and preload variables reach the children through the environment.

require 'fileutils'
require 'json'
require 'logger'
require 'securerandom'
require_relative 'soak/redis_server'
require_relative 'soak/sampler'
require_relative 'soak/swarm_process'

module WurkSoak
  class RssSoak
    FEATURE_CLASSES = { 'plain' => 'PlainJob', 'status' => 'TrackedJob', 'unique' => 'UniqueJob',
                        'limiter' => 'LimitedJob' }.freeze
    WAIT_TIMEOUT = 600
    SETTLE = 3

    def initialize(env = ENV)
      @jobs = Integer(env.fetch('RSS_JOBS', '100000'))
      @step = Integer(env.fetch('RSS_STEP', '10000'))
      @count = Integer(env.fetch('WURK_COUNT', '4'))
      @concurrency = Integer(env.fetch('RSS_CONCURRENCY', '5'))
      @app = env.fetch('RSS_APP', 'dummy')
      @features = env.fetch('RSS_FEATURES', 'plain').split(',').map(&:strip)
      unknown = @features - FEATURE_CLASSES.keys
      raise ArgumentError, "RSS_FEATURES: unknown #{unknown.join(', ')}" if unknown.any?

      @out = File.expand_path(env.fetch('RSS_OUT') { "tmp/rss/#{Time.now.strftime('%Y%m%d-%H%M%S')}.json" })
      @env = env
    end

    def call
      boot
      checkpoints = [checkpoint(0)]
      (@step..@jobs).step(@step) do |done|
        push(@step)
        wait_processed(done)
        checkpoints << checkpoint(done)
      end
      report(checkpoints)
    ensure
      @swarm&.stop
      @redis&.stop
    end

    private

    def boot
      FileUtils.mkdir_p(File.dirname(@out))
      @redis = RedisServer.new(dir: "#{@out}.redis", aof: false).start
      ENV['REDIS_URL'] = @redis.url
      require 'wurk'
      Wurk.configuration.logger = Logger.new(IO::NULL)
      require_relative 'soak/app'
      @swarm = SwarmProcess.new(env: { 'REDIS_URL' => @redis.url, 'WURK_COUNT' => @count.to_s,
                                       'SOAK_APP' => @app, 'SOAK_LIMIT' => '100000' },
                                log: "#{@out}.swarm.log", require_path: File.expand_path('soak/app.rb', __dir__),
                                concurrency: @concurrency)
      @swarm.start
      wait("#{@count} processes") { redis { |c| c.call('SCARD', 'processes') } >= @count }
      sleep SETTLE
      @pids = @swarm.children
    end

    def push(total)
      classes = @features.map { |f| WurkSoak.const_get(FEATURE_CLASSES.fetch(f)) }
      total.times.each_slice(1000).with_index do |slice, i|
        klass = classes[i % classes.size]
        args = slice.map { klass == UniqueJob ? [0, SecureRandom.hex(8)] : [0] }
        Wurk::Client.push_bulk('class' => klass, 'args' => args)
      end
    end

    def wait_processed(target)
      wait("#{target} processed") { redis { |c| c.call('GET', 'stat:processed').to_i } >= target }
      sleep SETTLE
    end

    def checkpoint(jobs)
      kids = @swarm.children
      warn "rss_soak: children changed #{@pids} -> #{kids}; slopes mix processes" if kids != @pids && jobs.positive?
      sample = redis { |c| Sampler.redis(c) }
      { jobs: jobs, children: kids.to_h { |pid| [pid, Sampler.memory(pid)] }.compact,
        parent: Sampler.memory(@swarm.pid), redis_used_memory: sample[:used_memory], redis_dbsize: sample[:dbsize] }
    end

    def report(checkpoints)
      slopes = child_slopes(checkpoints)
      result = { ruby: RUBY_VERSION, wurk: Wurk::VERSION, app: @app, features: @features, count: @count,
                 concurrency: @concurrency, env: knob_env, checkpoints: checkpoints, slopes_kb_per_10k: slopes }
      File.write(@out, JSON.pretty_generate(result))
      print_table(checkpoints, slopes)
      puts "json: #{@out}"
      0
    end

    def knob_env
      %w[WURK_PRELOAD_APP SIDEKIQ_PRELOAD_APP MALLOC_ARENA_MAX LD_PRELOAD RUBY_GC_HEAP_GROWTH_FACTOR]
        .to_h { |k| [k, @env[k]] }.compact
    end

    # `steady` drops the t=0 checkpoint: the first slice pays one-time warmup
    # (constants resolved, pools filled, CoW pages first written) that would
    # otherwise read as per-job growth.
    def child_slopes(checkpoints)
      @pids.to_h do |pid|
        series = ->(key) { checkpoints.filter_map { |c| (m = c[:children][pid]) && [c[:jobs] / 10_000.0, m[key]] } }
        slopes = lambda do |points|
          %i[rss pss private_dirty].to_h { |k| [k, Sampler.slope(points.call(k))&.round(1)] }
        end
        [pid, { all: slopes.call(series), steady: slopes.call(->(k) { series.call(k).drop(1) }) }]
      end
    end

    def print_table(checkpoints, slopes)
      puts "rss_soak: ruby #{RUBY_VERSION}, app=#{@app}, features=#{@features.join(',')}, " \
           "children=#{@count}x#{@concurrency}, #{knob_env}"
      puts 'jobs     pid          Rss kB     Pss kB   PrivDirty kB  shared'
      checkpoints.each do |c|
        c[:children].each do |pid, m|
          puts format('%-8d %-8d %10d %10d %14d %7.3f', c[:jobs], pid, m[:rss], m[:pss], m[:private_dirty],
                      m[:shared_ratio])
        end
        puts format('%-8d redis used_memory=%d dbsize=%d', c[:jobs], c[:redis_used_memory], c[:redis_dbsize])
      end
      slopes.each { |pid, s| puts "slope kB/10k jobs pid #{pid}: steady #{s[:steady]}  incl. warmup #{s[:all]}" }
    end

    def redis(&)
      c = @redis.client
      yield c
    ensure
      c&.close
    end

    def wait(what)
      deadline = monotonic + WAIT_TIMEOUT
      until yield
        raise "rss_soak: timed out waiting for #{what}" if monotonic > deadline

        sleep 0.2
      end
    end

    def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end

exit WurkSoak::RssSoak.new.call if $PROGRAM_NAME == __FILE__
