# frozen_string_literal: true

require_relative '../support'

# Shared harness for the algorithm benches (docs/plans/2026/11/10/101-evidence-
# driven-improvement-sweep/07-algorithms.md, "New benches"). Two kinds of
# number come out of them, and they are kept apart on purpose:
#
#   * Round trips and commands, counted CLIENT-side by a redis-client middleware
#     (Tally). Deterministic for a given seed shape and blind to any other
#     client on the server, so they are valid on a busy box and every bench
#     checks them against a budget and exits non-zero when one is exceeded.
#     A Lua script counts as the one EVALSHA the client sent; what the script
#     does inside is server-side and only `INFO commandstats` sees it.
#   * Wall-clock rates, printed as `<label> <n> (± e%) i/s` so bin/bench-compare
#     can diff them. Advisory: contended on a shared box. WURK_BENCH_COUNTS_ONLY=1
#     skips them, leaving the deterministic half for a CI gate.
#
# Each bench seeds and FLUSHDBs its own logical DB through bench_redis_url,
# never DB 0. Point REDIS_URL at a private server (`eval "$(bin/redis env
# algobench)"`); fast_delete.rb also reads `INFO commandstats`, which is
# server-wide.
module AlgoBench
  # redis-client middleware: one round trip per `call` / `call_pipelined`, and
  # the commands each one carried. Connection upkeep is not counted: the
  # prelude a (re)connect pipelines (HELLO, AUTH, SELECT, CLIENT) and the PING
  # redis-client sends before reusing a connection idle past `idle_timeout`.
  # Whether one lands in a measured window is timing; one stray reconnect read
  # as 2.01 round trips per job on a loaded box (bench/command_count.rb drops
  # the same commands, #915).
  module Tally
    LOCK = Mutex.new
    UPKEEP = %w[ping hello auth select client].freeze
    @round_trips = 0
    @commands = Hash.new(0)

    class << self
      def record(commands)
        commands = commands.reject { |command| UPKEEP.include?(command.first.to_s.downcase) }
        return if commands.empty?

        LOCK.synchronize do
          @round_trips += 1
          commands.each { |command| @commands[command.first.to_s.downcase] += 1 }
        end
      end

      def snapshot
        LOCK.synchronize { Count.new(@round_trips, @commands.values.sum, @commands.dup) }
      end
    end

    def call(command, config)
      Tally.record([command])
      super
    end

    def call_pipelined(commands, config)
      Tally.record(commands)
      super
    end
  end

  Count = Struct.new(:round_trips, :commands, :by_command) do
    def -(other)
      by = by_command.merge(other.by_command) { |_, mine, theirs| mine - theirs }.reject { |_, n| n.zero? }
      Count.new(round_trips - other.round_trips, commands - other.commands, by)
    end
  end

  module_function

  # `config.redis` options for a bench DB with the tally installed.
  def redis_options(default_db)
    { url: bench_redis_url(default_db), middlewares: [Tally] }
  end

  # Refuses a pool that is not on a numbered DB or does not carry the tally: a
  # pool built before `config.redis=` ran (a limiter constant built at load)
  # keeps REDIS_URL's DB 0 and counts nothing.
  def check_pool!(pool)
    db = URI.parse(pool.url).path.delete_prefix('/')
    raise "bench pool #{pool.url} is not on a numbered DB above 0" unless db.match?(/\A[1-9][0-9]*\z/)

    pool.with { |c| c.call('ECHO', 'tally') } # dials first, so only the ECHO is in the window
    seen = count { pool.with { |c| c.call('ECHO', 'tally') } }
    raise 'bench pool does not carry AlgoBench::Tally; set config.redis first' unless seen.round_trips == 1

    pool
  end

  # Round trips and commands the block cost.
  def count
    before = Tally.snapshot
    yield
    Tally.snapshot - before
  end

  # `count` for an operation whose cost scales with `per`: rounded per-unit.
  def print_count(label, count, per: 1)
    rt = count.round_trips.fdiv(per)
    cmds = count.commands.fdiv(per)
    top = count.by_command.sort_by { |_, n| -n }.first(4).map { |cmd, n| "#{cmd}=#{n}" }.join(' ')
    printf("  %-52s %10s round trips %10s commands  [%s]\n", label, num(rt), num(cmds), top)
  end

  def num(value)
    value == value.round ? value.round.to_s : format('%.2f', value)
  end

  # Deterministic gate. A count over budget is recorded and reported by
  # `finish!`, so one run shows every row that moved rather than the first.
  def budget!(label, value, budget)
    over = value > budget
    (@over ||= []) << format('%s: %s, over the budget of %s', label, num(value), num(budget)) if over
    printf("  %-52s %10s <= %-10s %s\n", "budget #{label}", num(value), num(budget), over ? 'OVER' : 'ok')
  end

  # `budget` is [round trips, commands]; either one over fails the run.
  def budget_count!(label, count, budget)
    budget!("#{label} (round trips)", count.round_trips, budget[0])
    budget!("#{label} (commands)", count.commands, budget[1])
  end

  # Exits non-zero when any budget was exceeded. abort writes to stderr, which
  # would otherwise land above the table it is a verdict on.
  def finish!
    $stdout.flush
    abort(['✗ over budget:', *@over].join("\n  ")) if @over&.any?
    puts '✓ every count within budget'
  end

  def counts_only?
    ENV['WURK_BENCH_COUNTS_ONLY'] == '1'
  end

  # Times runs of the block, with `setup` (untimed) before each
  # one — for operations that consume their own input (a delete, a retry_all)
  # and so cannot run under benchmark/ips. Stops early once the window from
  # bench_ips_window is spent, after at least `min` samples. Prints the mean
  # rate with its run-to-run spread in the benchmark/ips report shape.
  def timed(label, time:, min: 3, scale: 1, setup: nil)
    return if counts_only?

    window = bench_ips_window(time: time, warmup: 0)[:time]
    rates = []
    started = monotonic
    loop do
      setup&.call
      t0 = monotonic
      yield
      rates << (scale / (monotonic - t0))
      break if rates.size >= min && monotonic - started >= window
    end
    print_rate(label, rates)
  end

  def print_rate(label, rates)
    return if counts_only?

    mean = rates.sum / rates.size
    spread = rates.size > 1 ? Math.sqrt(rates.sum { |r| (r - mean)**2 } / (rates.size - 1)) : 0.0
    printf("%52s %s (± %.1f%%) i/s\n", label, human(mean), mean.zero? ? 0.0 : spread / mean * 100)
    mean
  end

  def human(value)
    return format('%.3f', value) if value < 100
    return format('%.1f', value) if value < 1_000
    return format('%.2fk', value / 1_000.0) if value < 1_000_000

    format('%.2fM', value / 1_000_000.0)
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Writes `rows` (Arrays of command args) in pipelines of `slice`, untallied
  # in spirit: seeding happens before any `count`.
  def seed(pool, rows, slice: 5_000)
    rows.each_slice(slice) do |chunk|
      pool.with { |c| c.pipelined { |p| chunk.each { |args| p.call(*args) } } }
    end
  end
end
