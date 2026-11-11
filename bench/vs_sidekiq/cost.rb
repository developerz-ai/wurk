# frozen_string_literal: true

require 'json'

module BenchVsSidekiq
  # The arithmetic behind bench/vs_sidekiq.rb's per-job cost and frame tables.
  # Its own file, like child_env.rb, so a test can drive it with hand-built
  # snapshots and stacks instead of a multi-minute benchmark.
  module Cost
    FIELDS = %i[cpu_us utime_us stime_us allocs gc_per_1k].freeze

    # Framework stages, matched against StackProf frame names. A sample goes
    # to the stage of its INNERMOST matching frame; frames no rule names
    # (redis-client, connection_pool, the pool adapters, core methods) are
    # transparent, so a Redis round trip is charged to the stage that issued
    # it. Within one frame the first rule wins, which is why the ACK rule sits
    # above the fetch rule (Wurk's UnitOfWork lives under Fetcher::). Both
    # engines' names are listed so one table compares like with like.
    STAGES = [
      ['job body (perform + INCR)', /\ABenchJob#/],
      ['GC', /\A\((garbage collection|marking|sweeping)\)\z/],
      ['job logger + log write', /\ALogger[#:]|Logger::|JobLogger#|::Context\./],
      ['payload parse', /load_json|\AJSON::Ext::Parser|Processor#parse_or_kill/],
      ['metrics middleware', /\A(Sidekiq::Metrics::|Wurk::Metrics::History)/],
      ['other built-in middleware',
       /\A(Wurk::Middleware::(?!Chain)|Wurk::(Batch|Limiter)::ServerMiddleware|Wurk::Metrics::Statsd|
          Sidekiq::Job::InterruptHandler)/x],
      ['middleware chain walk', /Middleware::Chain/],
      ['retry wrappers', /JobRetry#/],
      ['stats + work state', /Processor#stats|Processor::(SharedWorkState|Counter)/],
      ['ack bookkeeping',
       /UnitOfWork#(acknowledge|write_ack|release_)|Reliable#(defer_ack|take_pending_ack|flush_pending_acks)/],
      ['fetch (wurk: + pipelined ACK)', /Fetcher|BasicFetch|Processor#(fetch|get_one)/],
      ['heartbeat + background threads', /Launcher|Heartbeat|Scheduled|Manager#|Poller|Reaper|Leader|Cron|History#/],
      ['processor dispatch', /Processor#|Processor::IdentityReloader|Profiler\.call|block in <class:Config>/]
    ].freeze
    UNCLASSIFIED = 'unclassified'
    STAGE_NAMES = (STAGES.map(&:first) << UNCLASSIFIED).freeze

    # `first` and `last` are the JSON snapshots bench/vs_sidekiq/job.rb writes
    # at the first and last completion. Between them `jobs - 1` jobs finished.
    # Two pids means two processes wrote them, and the difference of two
    # processes' clocks is not a cost: nil.
    def self.per_job(first, last, jobs)
      a = JSON.parse(first)
      b = JSON.parse(last)
      return nil unless a['pid'] == b['pid']

      n = Float(jobs - 1)
      {
        cpu_us: (b['cpu'] - a['cpu']) * 1e6 / n,
        utime_us: (b['utime'] - a['utime']) * 1e6 / n,
        stime_us: (b['stime'] - a['stime']) * 1e6 / n,
        allocs: (b['allocated'] - a['allocated']) / n,
        gc_per_1k: (b['gc'] - a['gc']) * 1000 / n
      }
    end

    def self.median_of(costs)
      return nil if costs.empty?

      FIELDS.to_h { |field| [field, median(costs.map { |c| c.fetch(field) })] }
    end

    def self.median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    # In: { side => [[profile, cost], ...] }, one pair per profiled run (the
    # driver interleaves the sides), `jobs` completions per run. Each run's
    # sample shares are scaled by that same run's measured CPU per job, so a
    # run slowed by a busy box moves its own numbers, not another run's. Out,
    # per side: the median µs/job of every stage and self (leaf) frame, and
    # each run's stage numbers so the table can show the gap's spread.
    def self.attribute(runs, jobs)
      runs.to_h do |side, pairs|
        [side.to_s, summarize(pairs.map { |profile, cost| run_attribution(profile, cost, jobs) })]
      end
    end

    def self.summarize(per_run)
      field = ->(key) { per_run.map { |r| r[key] } }
      {
        'runs' => per_run.size,
        'cpu_us' => median(field['cpu_us']),
        'samples' => field['samples'].sum,
        'coverage' => median(field['coverage']),
        'stages' => median_hash(field['stages']),
        'self' => median_hash(field['self']),
        'stage_self' => STAGE_NAMES.to_h { |s| [s, median_hash(field['stage_self'].map { |h| h.fetch(s, {}) })] },
        'stage_runs' => field['stages']
      }
    end

    def self.run_attribution(profile, cost, jobs)
      stages, leaves, by_stage, total = tally(profile)
      cpu_us = cost.fetch(:cpu_us)
      scale = ->(counts) { counts.transform_values { |w| w.to_f * cpu_us / total } }
      {
        'cpu_us' => cpu_us, 'samples' => total,
        # Sampled CPU / measured CPU. ITIMER_PROF only fires on a scheduler
        # tick, so an interval below the tick silently becomes the tick: this
        # ratio is how a reader sees that happen.
        'coverage' => total * profile.fetch(:interval) / (cpu_us * (jobs - 1)),
        'stages' => scale.call(stages), 'self' => scale.call(leaves),
        'stage_self' => by_stage.transform_values { |counts| scale.call(counts) }
      }
    end

    def self.median_hash(hashes)
      hashes.flat_map(&:keys).uniq.to_h { |k| [k, median(hashes.map { |h| h.fetch(k, 0.0) })] }
    end

    def self.tally(profile)
      raw = profile.fetch(:raw)
      names = profile.fetch(:frames).transform_values { |f| f[:name] }
      stages = Hash.new(0)
      leaves = Hash.new(0)
      by_stage = Hash.new { |h, k| h[k] = Hash.new(0) }
      total = 0
      i = 0
      while (len = raw[i])
        stack = raw[i + 1, len].map { |id| names.fetch(id) }
        weight = raw[i + 1 + len]
        i += len + 2
        total += weight
        stage = stage_of(stack)
        leaf = normalize(stack.last)
        stages[stage] += weight
        leaves[leaf] += weight
        by_stage[stage][leaf] += weight
      end
      raise 'bench/vs_sidekiq: the profile holds no samples' if total.zero?

      [stages, leaves, by_stage, total]
    end

    # `stack` is root first, as StackProf records it.
    def self.stage_of(stack)
      stack.reverse_each do |name|
        STAGES.each { |stage, rule| return stage if rule.match?(name) }
      end
      UNCLASSIFIED
    end

    # The self-frame view compares a frame with its namesake on the other
    # side, so the engine prefix goes: Wurk::Logger::Formatters::Pretty#call
    # and Sidekiq::Logger::Formatters::Pretty#call are one row.
    def self.normalize(name) = name.sub(/\A(Wurk|Sidekiq)::/, '')

    def self.frame_table(attribution, self_rows: 20, drill_stages: 3, drill_rows: 8)
      sk = attribution.fetch('sidekiq')
      wk = attribution.fetch('wurk')
      gap = wk['cpu_us'] - sk['cpu_us']
      lines = stage_table(sk, wk, gap)
      lines << ''
      lines << format('%d profiled run(s) per side; samples: sidekiq %d, wurk %d; ' \
                      'sampled/measured CPU %.0f%% / %.0f%%',
                      wk['runs'], sk['samples'], wk['samples'], sk['coverage'] * 100, wk['coverage'] * 100)
      lines << ''
      lines << "Largest self-frame differences (leaf frame, engine prefix dropped), top #{self_rows} by |Δ|:"
      lines << ''
      lines.concat(self_table(sk['self'], wk['self'], gap, self_rows))
      top_stages(sk, wk, drill_stages).each do |stage|
        lines << ''
        lines << "Inside \"#{stage}\", top #{drill_rows} self frames by |Δ|:"
        lines << ''
        lines.concat(self_table(sk['stage_self'].fetch(stage, {}), wk['stage_self'].fetch(stage, {}), gap,
                                drill_rows))
      end
      lines.join("\n")
    end

    def self.stage_table(base, wurk, gap)
      lines = ['| stage | Sidekiq µs/job | Wurk µs/job | Δ µs/job | Δ range over runs | share of gap |',
               '|---|---|---|---|---|---|']
      STAGE_NAMES.each do |stage|
        a = base['stages'].fetch(stage, 0.0)
        b = wurk['stages'].fetch(stage, 0.0)
        next if a.zero? && b.zero?

        deltas = base['stage_runs'].zip(wurk['stage_runs']).map { |s, w| w.fetch(stage, 0.0) - s.fetch(stage, 0.0) }
        lines << format('| %s | %.1f | %.1f | %+.1f | %+.1f … %+.1f | %s |', stage, a, b, b - a,
                        deltas.min, deltas.max, share(b - a, gap))
      end
      lines << format('| **total CPU** | %.1f | %.1f | %+.1f | | 100%% |', base['cpu_us'], wurk['cpu_us'], gap)
    end

    def self.self_table(base, wurk, gap, rows)
      keys = (base.keys | wurk.keys).max_by(rows) { |k| (wurk.fetch(k, 0.0) - base.fetch(k, 0.0)).abs }
      ['| self frame | Sidekiq µs/job | Wurk µs/job | Δ µs/job | share of gap |', '|---|---|---|---|---|'] +
        keys.map do |k|
          a = base.fetch(k, 0.0)
          b = wurk.fetch(k, 0.0)
          format('| `%s` | %.1f | %.1f | %+.1f | %s |', k, a, b, b - a, share(b - a, gap))
        end
    end

    def self.top_stages(base, wurk, count)
      STAGE_NAMES.max_by(count) { |s| wurk['stages'].fetch(s, 0.0) - base['stages'].fetch(s, 0.0) }
    end

    def self.share(delta, gap) = gap.zero? ? 'n/a' : format('%+.0f%%', delta / gap * 100)

    # StackProf.results writes a Marshal dump. Both sides run the same Ruby,
    # and the file is one this harness's own child just wrote.
    def self.load_profile(path)
      Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad
    end
  end
end
