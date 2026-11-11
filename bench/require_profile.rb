# frozen_string_literal: true

# Require-time profile — the L0 row of docs/plans/2026/11/10/101-evidence-
# driven-improvement-sweep/06-perf-hot-path-boot.md. Every lazy-loading tier
# (L1–L7) cites its before/after from this script.
#
# For each entry point it boots FRESH interpreters with this file preloaded as
# a hook (`ruby -rbundler/setup -r bench/require_profile.rb …`) and records,
# per loaded file: inclusive wall time, exclusive time with GC taken out, the
# GC that ran during its own body, inclusive and exclusive allocated objects,
# and the file that required it. Per entry point: loaded
# feature count, allocations, GC time and RSS delta over the window — those
# totals from a second set of runs with the Kernel patch off, because the patch
# adds a few allocations per require call it cannot net out (Wurk makes more
# require calls than Sidekiq, so a hooked total would bias the comparison).
#
#   wurk:client   `require "wurk"` — what a Puma worker that only enqueues pays
#   wurk:server   `exe/wurk -r <noop app>` from interpreter start to the first
#                 Fetcher::Reliable#retrieve_work call (needs Redis)
#   wurk:rails    `require "wurk/rails"` on top of an already-loaded Rails
#                 (rails + action_controller + active_job are the baseline,
#                 so only what Wurk adds is on the clock)
#   sidekiq:*     the same entries against stock Sidekiq, from the isolated
#                 bench/vs_sidekiq bundle (`--sidekiq`). No sidekiq:rails: that
#                 bundle has no Rails in it.
#
# The window opens after `bundler/setup` on both sides, so Bundler's own load
# is nobody's cost. Both `require` and `require_relative` are hooked (the
# latter resolved against its caller, as Ruby does). `load` and `Kernel.require` with an explicit receiver are
# not hooked; neither appears on these boot paths. The hook nets its own time
# and allocations out of every per-file number.
#
# `--usage` adds two Coverage runs (method-level) that answer which Wurk files a
# pure enqueuer actually calls into, and which a server calls into by the time
# it has processed one job. Methods that ran while `require "wurk"` itself was
# loading are subtracted: only calls after it returned count as use.
#
# Feature and allocation counts are deterministic for a given tree and Ruby;
# times are wall clock and need a quiet host. Not a regression gate: no ips line.
#
#   bundle exec ruby bench/require_profile.rb [--runs N] [--top N] [--sidekiq]
#                                             [--usage] [--json PATH]
#                                             [--entries a,b,…]
#
# Redis: wurk:server, sidekiq:server and every --usage run (the client's
# enqueues too) use a dedicated logical DB (default 12, `WURK_BENCH_DB`
# overrides), FLUSHDB'd before each run. DB 0 is never touched.
module RequireProfile
  HOOK_ENV = 'WURK_REQPROF_OUT'

  # Child side. Core Ruby only: anything this module required would land in the
  # baseline and vanish from the entry point's own count.
  module Hook
    @stack = []
    @records = []
    @recording = true
    # The hook's own time and allocations, taken back out of every number so
    # the counts match an unhooked run.
    @hook_t = 0.0
    @hook_alloc = 0

    class << self
      def start(stop: nil, stop_count: 1)
        @stop = stop.to_s.empty? ? nil : stop.split('#', 2)
        @stop_count = stop_count
        @stop_calls = 0
        GC::Profiler.enable
        # +1: Ruby provides this file itself once its body (and so this call)
        # returns, and it is not the entry's.
        @base = { t: now, alloc: allocated, gc: gc_time, rss: rss_kb, features: $LOADED_FEATURES.size + 1 }
      end

      # Seconds of GC so far. A collection is charged to whichever file is
      # loading when the heap fills, and since allocation counts are
      # deterministic it lands on the same innocent file every run; this is what
      # takes it back out of that file's own time.
      def gc_time = GC::Profiler.total_time

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def allocated = GC.stat(:total_allocated_objects)

      def rss_kb
        line = File.foreach('/proc/self/status').find { |l| l.start_with?('VmRSS:') }
        line && Integer(line.split[1])
      rescue SystemCallError
        nil
      end

      # `entered_*` are read first thing in the Kernel patch, so the work done
      # there (resolving a require_relative) is charged to the hook too.
      def around(feature, entered_t = now, entered_a = allocated)
        return yield unless @recording

        # [start, allocs, gc, children's time, children's allocs, children's gc]
        frame = [0.0, 0, gc_time, 0.0, 0, 0.0]
        @stack.push(frame)
        frame[0], frame[1] = hook_resume(entered_t, entered_a)
        loaded = false
        begin
          loaded = yield
        ensure
          back_t = now
          back_a = allocated
          @stack.pop
          record(feature, frame, back_t - @hook_t, back_a - @hook_alloc) if loaded
          hook_resume(back_t, back_a)
        end
        loaded
      end

      # Charges everything since (t, a) to the hook; returns the net clocks.
      def hook_resume(since_t, since_a)
        t = now
        a = allocated
        @hook_t += t - since_t
        @hook_alloc += a - since_a
        [t - @hook_t, a - @hook_alloc]
      end

      # Ruby provides a feature after its body runs, so a file's children are
      # already recorded when it finishes; it adopts those one level below it.
      def record(feature, frame, net_t, net_a)
        incl_t = net_t - frame[0]
        incl_a = net_a - frame[1]
        incl_gc = gc_time - frame[2]
        if (parent = @stack.last)
          parent[3] += incl_t
          parent[4] += incl_a
          parent[5] += incl_gc
        end
        excl_gc = incl_gc - frame[5]
        rec = { path: $LOADED_FEATURES.last, request: feature.to_s, depth: @stack.size, parent: nil,
                incl_ms: incl_t * 1000.0, excl_ms: (incl_t - frame[3] - excl_gc) * 1000.0, gc_ms: excl_gc * 1000.0,
                incl_alloc: incl_a, excl_alloc: incl_a - frame[4] }
        @records.reverse_each do |child|
          break if child[:depth] <= rec[:depth]

          child[:parent] ||= rec[:path] if child[:depth] == rec[:depth] + 1
        end
        @records << rec
        @coverage_base ||= method_counts if @stack.empty? && coverage?
      end

      # Called by the server entries' app file, which the CLI requires after
      # the library and before it starts fetching. Arming there rather than
      # from the require hook keeps the stop working in the unhooked control
      # run. `const_get` may load an autoloaded fetcher a little early; the
      # server loads it before its first fetch anyway.
      def app_loaded
        return unless @stop

        meth = @stop[1].to_sym
        hook = self
        Object.const_get(@stop[0]).prepend(Module.new do
          define_method(meth) do |*args, **kw, &blk|
            hook.stop_reached!
            super(*args, **kw, &blk)
          end
        end)
      end

      def stop_reached!
        @stop_calls += 1
        return if @stop_calls < @stop_count

        finish
        exit!(0)
      end

      def finish
        return unless @recording

        @recording = false
        rss = rss_kb
        File.binwrite(ENV.fetch(HOOK_ENV), Marshal.dump(
                                             wall_ms: (now - @base[:t]) * 1000.0,
                                             features: $LOADED_FEATURES.size - @base[:features],
                                             allocations: allocated - @hook_alloc - @base[:alloc],
                                             hook_ms: @hook_t * 1000.0,
                                             gc_ms: (gc_time - @base[:gc]) * 1000.0,
                                             rss_kb: rss && @base[:rss] ? rss - @base[:rss] : nil,
                                             records: @records, coverage: coverage_summary
                                           ))
      end

      def coverage? = defined?(::Coverage) && ::Coverage.running?

      def method_counts
        ::Coverage.peek_result.to_h { |path, cov| [path, cov[:methods] || {}] }
      end

      # path → number of methods that ran after the first top-level require
      # returned. Calls made while the entry's own library loaded (a constant
      # built in a class body) are not use.
      def coverage_summary
        return unless coverage?

        base = @coverage_base || {}
        method_counts.to_h do |path, methods|
          before = base.fetch(path, {})
          [path, methods.count { |key, n| n > before.fetch(key, 0) }]
        end
      end

      def install
        if ENV['WURK_REQPROF_COVERAGE'] == '1'
          require 'coverage'
          ::Coverage.start(methods: true)
        end
        ENV.fetch('WURK_REQPROF_PRELOAD', '').split(',').each { |f| require f }
        start(stop: ENV.fetch('WURK_REQPROF_STOP', nil), stop_count: Integer(ENV.fetch('WURK_REQPROF_STOP_COUNT', '1')))
        Kernel.prepend(KernelPatch) unless ENV['WURK_REQPROF_PLAIN'] == '1'
        at_exit { finish }
      end
    end

    # Prepended to Kernel so it wraps RubyGems' (and Zeitwerk's) require.
    module KernelPatch
      private

      def require(feature)
        RequireProfile::Hook.around(feature) { super }
      end

      # Kernel#require_relative resolves against its caller's file, which would
      # be this one from inside a `super`: resolve here and hand it the absolute
      # path. It loads without dispatching to #require, so one record per file.
      def require_relative(feature)
        entered_t = RequireProfile::Hook.now
        entered_a = RequireProfile::Hook.allocated
        base = caller_locations(1, 1).first&.absolute_path
        path = base ? File.expand_path(feature, File.dirname(base)) : feature.to_s
        raise LoadError, "cannot infer basepath for #{feature}" unless File.absolute_path?(path)

        RequireProfile::Hook.around(feature, entered_t, entered_a) { super(path) }
      end
    end
  end

  # Pure aggregation over child results.
  module Stats
    module_function

    def median(values)
      sorted = values.compact.sort
      return nil if sorted.empty?

      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    # path → "wurk", "gem:<name>", "stdlib/<lib>" or "other".
    def group_for(path, wurk_lib:, rubylibdirs:)
      return 'wurk' if path.start_with?("#{wurk_lib}/")
      return "gem:#{Regexp.last_match(1)}" if path =~ %r{/gems/([^/]+?)-\d[^/]*/}

      dir = rubylibdirs.find { |d| path.start_with?("#{d}/") }
      return 'other' unless dir

      "stdlib/#{path.delete_prefix("#{dir}/").split('/').first.sub(/\.(rb|so|bundle)\z/, '')}"
    end

    # N hooked runs (per-file attribution) and N unhooked control runs (the
    # entry's totals) → counts as [min, max] (a spread means the count is not
    # deterministic), times as medians, per-file allocations from run one. The
    # hook leaves a few allocations per require call it cannot net out (method
    # caches inside `super`), so totals come from the control runs.
    def summarize(hooked, plain = hooked)
      per_file = Hash.new { |h, k| h[k] = [] }
      hooked.each { |run| run[:records].each { |rec| per_file[rec[:path]] << rec } }
      totals(plain).merge(
        runs: hooked.size,
        require_ms: median(hooked.map { |r| top_level_ms(r[:records]) }),
        hooked_allocations: hooked.map { |r| r[:allocations] }.minmax,
        files: per_file.map { |path, recs| file_row(path, recs) }
      )
    end

    def totals(runs)
      { wall_ms: median(runs.map { |r| r[:wall_ms] }), gc_ms: median(runs.map { |r| r[:gc_ms] }),
        rss_kb: median(runs.map { |r| r[:rss_kb] }), features: runs.map { |r| r[:features] }.minmax,
        allocations: runs.map { |r| r[:allocations] }.minmax }
    end

    def top_level_ms(records) = records.select { |rec| rec[:depth].zero? }.sum { |rec| rec[:incl_ms] }

    def file_row(path, recs)
      first = recs.first
      { path: path, parent: first[:parent], excl_ms: median(recs.map { |r| r[:excl_ms] }),
        gc_ms: median(recs.map { |r| r[:gc_ms] }),
        incl_ms: median(recs.map { |r| r[:incl_ms] }), excl_alloc: first[:excl_alloc], incl_alloc: first[:incl_alloc] }
    end

    def groups(files, classify)
      by_group = files.group_by { |f| classify.call(f[:path]) }
      rows = by_group.map do |group, fs|
        { group: group, files: fs.size, excl_ms: fs.sum { |f| f[:excl_ms] }, excl_alloc: fs.sum { |f| f[:excl_alloc] } }
      end
      rows.sort_by { |g| -g[:excl_ms] }
    end

    # Tier by observed use: a file the enqueue run called into is client tier,
    # one only the server run called into is server tier, the rest are
    # on-demand candidates. A constants-only file (errors, keys) shows as
    # unused and needs a human look before it moves.
    def usage_tier(path, client_cov, server_cov)
      if client_cov.fetch(path, 0).positive? then 'client'
      elsif server_cov.fetch(path, 0).positive? then 'server'
      else 'unused'
      end
    end
  end

  # Spawns one profiled child per entry point and run.
  module Runner
    # `bundle` is :wurk (repo Gemfile) or :sidekiq (bench/vs_sidekiq/Gemfile).
    Entry = Struct.new(:name, :bundle, :argv, :stop, :preload, :redis, :usage_argv)

    APP_SOURCE = <<~RUBY
      class ReqProfNoopJob
        include Sidekiq::Job

        def perform(*); end
      end
      RequireProfile::Hook.app_loaded
    RUBY

    ENQUEUE_SNIPPET = <<~RUBY
      class ReqProfEnqueueJob
        include Sidekiq::Job

        def perform(*); end
      end
      ReqProfEnqueueJob.perform_async(1, 'a')
      ReqProfEnqueueJob.perform_in(60, 2)
      ReqProfEnqueueJob.set(queue: 'other').perform_async(3)
      Sidekiq::Client.push_bulk('class' => ReqProfEnqueueJob, 'args' => [[4], [5]])
    RUBY

    RAILS_BASELINE = 'rails,action_controller/railtie,active_job/railtie'

    module_function

    def root = File.expand_path('..', __dir__)

    def entries(app)
      exe = File.join(root, 'exe', 'wurk')
      server = ['-r', app, '-c', '1', '-q', 'default']
      [
        Entry.new('wurk:client', :wurk, ['-e', 'require "wurk"'], nil, nil, false,
                  ['-e', "require 'wurk'\n#{ENQUEUE_SNIPPET}"]),
        Entry.new('wurk:server', :wurk, [exe, *server], 'Wurk::Fetcher::Reliable#retrieve_work', nil, true,
                  [exe, *server]),
        Entry.new('wurk:rails', :wurk, ['-e', 'require "wurk/rails"'], nil, RAILS_BASELINE, false, nil),
        Entry.new('sidekiq:client', :sidekiq, ['-e', 'require "sidekiq"'], nil, nil, false, nil),
        Entry.new('sidekiq:server', :sidekiq, [:sidekiq_bin, *server], 'Sidekiq::BasicFetch#retrieve_work', nil,
                  true, nil)
      ]
    end

    def profile(opts, dir)
      app = File.join(dir, 'reqprof_app.rb')
      File.write(app, APP_SOURCE)
      selected = entries(app).select do |e|
        (opts[:sidekiq] || e.bundle == :wurk) && (opts[:only].nil? || opts[:only].include?(e.name))
      end
      data = { meta: meta(opts), entries: {}, usage: {} }
      selected.each do |entry|
        hooked = Array.new(opts[:runs]) { |i| spawn_entry(entry, dir, "hooked#{i}") }
        plain = Array.new(opts[:runs]) { |i| spawn_entry(entry, dir, "plain#{i}", mode: :plain) }
        data[:entries][entry.name] = Stats.summarize(hooked, plain)
      end
      data[:usage] = usage_runs(selected, dir) if opts[:usage]
      data
    end

    def meta(opts)
      loadavg = File.exist?('/proc/loadavg') ? File.read('/proc/loadavg').split.first(3).join(' ') : 'n/a'
      { ruby: RUBY_DESCRIPTION, at: Time.now.utc.iso8601, runs: opts[:runs], loadavg: loadavg,
        git: IO.popen(['git', '-C', root, 'rev-parse', '--short', 'HEAD'], err: File::NULL, &:read).strip }
    end

    def usage_runs(selected, dir)
      client = selected.find { |e| e.name == 'wurk:client' }
      server = selected.find { |e| e.name == 'wurk:server' }
      return {} unless client && server

      # The second fetch call comes after the seeded job ran, so Processor and
      # the server middleware chain register as used.
      { client: spawn_entry(client, dir, 'usage', mode: :usage)[:coverage],
        server: spawn_entry(server, dir, 'usage', mode: :usage, seed: true, stop_count: 2)[:coverage] }
    end

    # mode: :hooked (per-file), :plain (no Kernel patch: the entry's totals) or
    # :usage (hooked plus method coverage, with the entry's usage script).
    def spawn_entry(entry, dir, tag, mode: :hooked, seed: false, stop_count: 1)
      base = File.join(dir, "#{entry.name.tr(':', '_')}-#{tag}")
      prepare_redis(seed) if redis?(entry, mode)
      argv = (mode == :usage ? entry.usage_argv : entry.argv).map { |a| a == :sidekiq_bin ? sidekiq_bin : a }
      cmd = [RbConfig.ruby, '-rbundler/setup', '-r', File.expand_path(__FILE__), *argv]
      env = child_env(entry, "#{base}.bin", mode, stop_count)
      pid = with_clean_env { Process.spawn(env, *cmd, chdir: root, out: "#{base}.log", err: %i[child out]) }
      _, status = Process.wait2(pid)
      unless status.success? && File.exist?("#{base}.bin")
        raise "#{entry.name} exited #{status.exitstatus}:\n#{File.read("#{base}.log")}"
      end

      Marshal.load(File.binread("#{base}.bin")) # rubocop:disable Security/MarshalLoad -- our own child's output
    end

    def child_env(entry, out, mode, stop_count)
      env = { HOOK_ENV => out, 'BUNDLE_GEMFILE' => gemfile(entry.bundle), 'RUBYOPT' => nil, 'RUBYLIB' => nil,
              'WURK_REQPROF_STOP' => entry.stop, 'WURK_REQPROF_STOP_COUNT' => stop_count.to_s,
              'WURK_REQPROF_PRELOAD' => entry.preload, 'WURK_REQPROF_COVERAGE' => mode == :usage ? '1' : nil,
              'WURK_REQPROF_PLAIN' => mode == :plain ? '1' : nil }
      env['REDIS_URL'] = redis_url if redis?(entry, mode)
      env
    end

    # A usage run enqueues (the client) or fetches (the server), so it gets
    # the benchmark DB whatever the entry's own runs need: an inherited
    # REDIS_URL would land its jobs in the caller's store.
    def redis?(entry, mode) = entry.redis || mode == :usage

    def gemfile(bundle)
      bundle == :wurk ? File.join(root, 'Gemfile') : File.join(root, 'bench', 'vs_sidekiq', 'Gemfile')
    end

    # The children pick their own bundle; a parent `bundle exec` must not leak
    # its RUBYOPT/BUNDLE_GEMFILE into the Sidekiq side.
    def with_clean_env(&)
      defined?(::Bundler) ? ::Bundler.with_unbundled_env(&) : yield
    end

    def sidekiq_bin
      @sidekiq_bin ||= begin
        script = 'print Gem.bin_path("sidekiq", "sidekiq")'
        path = with_clean_env do
          IO.popen({ 'BUNDLE_GEMFILE' => gemfile(:sidekiq) }, [RbConfig.ruby, '-rbundler/setup', '-e', script], &:read)
        end
        raise 'stock Sidekiq bundle missing: BUNDLE_GEMFILE=bench/vs_sidekiq/Gemfile bundle install' if path.empty?

        path
      end
    end

    def redis_url
      require_relative 'support'
      @redis_url ||= bench_redis_url('12')
    end

    def prepare_redis(seed)
      require 'redis-client'
      conn = RedisClient.config(url: redis_url).new_client
      conn.call('FLUSHDB')
      return unless seed

      now = Time.now.to_f
      job = { 'class' => 'ReqProfNoopJob', 'args' => [], 'queue' => 'default', 'retry' => false,
              'jid' => 'reqprof0000000000000000', 'created_at' => now, 'enqueued_at' => now }
      conn.call('SADD', 'queues', 'default')
      conn.call('LPUSH', 'queue:default', JSON.generate(job))
    ensure
      conn&.close
    end
  end

  # Markdown tables on stdout, raw data as JSON.
  module Report
    module_function

    def print(data, top:)
      classify = classifier
      meta = data[:meta]
      puts "# require profile — #{meta[:ruby]}"
      puts "git #{meta[:git]}, #{meta[:at]}, loadavg #{meta[:loadavg]}, #{meta[:runs]} runs/entry\n\n"
      summary(data[:entries], classify)
      data[:entries].each do |name, s|
        groups(name, s, classify)
        top_files(name, s, top)
      end
      usage(data, classify) if data[:entries]['wurk:client'] && !data[:usage].empty?
    end

    def classifier
      wurk_lib = File.join(Runner.root, 'lib')
      dirs = [RbConfig::CONFIG['rubyarchdir'], RbConfig::CONFIG['rubylibdir']]
      lambda do |path|
        group = Stats.group_for(path, wurk_lib: wurk_lib, rubylibdirs: dirs)
        group == 'gem:sidekiq' ? 'sidekiq' : group
      end
    end

    def summary(entries, classify)
      puts '| entry | wall ms | require ms | GC ms | features | own files | allocations | RSS delta MB |'
      puts '|---|--:|--:|--:|--:|--:|--:|--:|'
      entries.each do |name, s|
        own = s[:files].count { |f| %w[wurk sidekiq].include?(classify.call(f[:path])) }
        rss = s[:rss_kb] ? format('%.1f', s[:rss_kb] / 1024.0) : 'n/a'
        puts format('| %s | %.0f | %.0f | %.0f | %s | %d | %s | %s |', name, s[:wall_ms], s[:require_ms], s[:gc_ms],
                    span(s[:features]), own, span(s[:allocations]), rss)
      end
    end

    def groups(name, summary, classify)
      puts "\n## #{name}: groups by exclusive time\n\n| group | files | excl ms | excl allocs |\n|---|--:|--:|--:|"
      Stats.groups(summary[:files], classify).first(15).each do |g|
        puts format('| %s | %d | %.1f | %d |', g[:group], g[:files], g[:excl_ms], g[:excl_alloc])
      end
    end

    def top_files(name, summary, top)
      puts "\n## #{name}: top #{top} files by exclusive time\n\n" \
           "| file | excl ms | GC ms | incl ms | excl allocs | required by |\n|---|--:|--:|--:|--:|---|"
      summary[:files].sort_by { |f| -f[:excl_ms] }.first(top).each do |f|
        puts format('| %s | %.2f | %.2f | %.2f | %d | %s |', short(f[:path]), f[:excl_ms], f[:gc_ms], f[:incl_ms],
                    f[:excl_alloc], f[:parent] ? short(f[:parent]) : '(entry)')
      end
    end

    def usage(data, classify)
      client_cov = data[:usage].fetch(:client)
      server_cov = data[:usage].fetch(:server)
      rows = data[:entries]['wurk:client'][:files].select { |f| classify.call(f[:path]) == 'wurk' }.map do |f|
        f.merge(tier: Stats.usage_tier(f[:path], client_cov, server_cov))
      end
      puts "\n## wurk files loaded by `require \"wurk\"`, by observed use\n\n" \
           'client: a method ran during enqueue. server: ran only by the time a server had processed one job. ' \
           'unused: neither. Load-time calls do not count; constants-only files (errors, keys) land in ' \
           "unused but may still be referenced.\n\n" \
           "| tier | files | excl ms | excl allocs |\n|---|--:|--:|--:|"
      rows.group_by { |r| r[:tier] }.sort.each do |tier, rs|
        puts format('| %s | %d | %.1f | %d |', tier, rs.size, rs.sum { |r| r[:excl_ms] }, rs.sum { |r| r[:excl_alloc] })
      end
      puts "\n| file | tier | excl ms | excl allocs |\n|---|---|--:|--:|"
      rows.sort_by { |r| [r[:tier], -r[:excl_ms]] }.each do |r|
        puts format('| %s | %s | %.2f | %d |', short(r[:path]), r[:tier], r[:excl_ms], r[:excl_alloc])
      end
    end

    def span((min, max)) = min == max ? min.to_s : "#{min}–#{max}"

    def short(path)
      path.sub("#{Runner.root}/", '').sub(%r{\A.*/gems/}, '')
          .sub("#{RbConfig::CONFIG['rubyarchdir']}/", 'stdlib/').sub("#{RbConfig::CONFIG['rubylibdir']}/", 'stdlib/')
    end
  end

  def self.run_cli(argv)
    require 'fileutils'
    require 'json'
    require 'optparse'
    require 'rbconfig'
    require 'time'
    require 'tmpdir'
    opts = { runs: 3, top: 25, sidekiq: false, usage: false, json: nil, only: nil }
    OptionParser.new do |o|
      o.on('--runs N', Integer, 'fresh interpreters per entry (default 3)') { |v| opts[:runs] = v }
      o.on('--top N', Integer, 'files per top table (default 25)') { |v| opts[:top] = v }
      o.on('--sidekiq', 'also profile stock Sidekiq (bench/vs_sidekiq bundle)') { opts[:sidekiq] = true }
      o.on('--usage', 'add the Coverage runs behind the client/server tier split') { opts[:usage] = true }
      o.on('--json PATH', 'write raw data') { |v| opts[:json] = v }
      o.on('--entries LIST', 'comma-separated entry names') { |v| opts[:only] = v.split(',') }
    end.parse!(argv)
    data = Dir.mktmpdir('require_profile') { |dir| Runner.profile(opts, dir) }
    Report.print(data, top: opts[:top])
    return unless opts[:json]

    FileUtils.mkdir_p(File.dirname(opts[:json]))
    File.write(opts[:json], JSON.pretty_generate(data))
    puts "\nwrote #{opts[:json]}"
  end
end

if ENV[RequireProfile::HOOK_ENV] && $PROGRAM_NAME != __FILE__
  RequireProfile::Hook.install
elsif $PROGRAM_NAME == __FILE__
  RequireProfile.run_cli(ARGV)
end
