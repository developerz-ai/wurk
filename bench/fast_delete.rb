# frozen_string_literal: true

require 'logger'
require 'json'
require 'wurk'
require_relative 'algo/support'

# The Pro Fast API deletes on a big queue — row 07-A3 of docs/plans/2026/11/10/
# 101-evidence-driven-improvement-sweep/07-algorithms.md. Both scripts
# (Lua::FAST_DELETE_JOB, FAST_DELETE_BY_CLASS) copy the whole list into the
# Lua heap (`lrange 0 -1`), then LREM each match from the head; Redis serves
# no other client meanwhile. The dashboard's "delete job" button is
# Queue#delete_job.
#
#   delete_by_class — removes VICTIMS jobs of one class from a queue of SIZE.
#   delete_job      — removes one job by jid.
#
# Victims sit at the tail, the oldest end, so each LREM walks the whole list
# first: the worst case, and where a backed-up queue's stuck jobs are.
#
# Two numbers per row, both advisory, both i/s-shaped: the client-side rate,
# and `INFO commandstats` evalsha usec_per_call turned into calls/s — the time
# Redis spent blocked inside the script. commandstats is server-wide, so run on
# a private server. Nothing here is a count, so WURK_BENCH_COUNTS_ONLY=1 runs
# no rows. The removed count is checked, so a delete that silently
# finds nothing fails the run.
#
#   eval "$(bin/redis env algobench)"
#   bundle exec ruby -Ilib bench/fast_delete.rb
#
# Dedicated logical DB (default 5), FLUSHDB'd before and after. Never DB 0.

SIZE    = Integer(ENV.fetch('WURK_BENCH_FAST_DELETE_SIZE', '100000'))
VICTIMS = Integer(ENV.fetch('WURK_BENCH_FAST_DELETE_VICTIMS', '100'))
QUEUE   = 'fastdel'

config = Wurk.configuration
config.logger = Logger.new(IO::NULL)
config.redis = AlgoBench.redis_options('5')
POOL = AlgoBench.check_pool!(config.redis_pool)
Q = Wurk::Queue.new(QUEUE)

def payload(klass, index)
  JSON.dump('class' => klass, 'args' => [index], 'queue' => QUEUE, 'jid' => format('%024x', index),
            'created_at' => 1_700_000_000.0, 'enqueued_at' => 1_700_000_000.0, 'retry' => true)
end

def tail!(klass, from, count)
  AlgoBench.seed(POOL, Array.new(count) { |i| ['RPUSH', "queue:#{QUEUE}", payload(klass, from + i)] })
end

def evalsha_stats
  line = POOL.with { |c| c.call('INFO', 'commandstats') }[/^cmdstat_evalsha:.*$/].to_s
  [line[/calls=(\d+)/, 1].to_i, line[/usec=(\d+)/, 1].to_i]
end

# Client rate, then the server's own time inside the script over those runs.
def run(label, setup:, &)
  return if AlgoBench.counts_only?

  calls0, usec0 = evalsha_stats
  AlgoBench.timed(label, time: 5, setup: setup, &)
  calls1, usec1 = evalsha_stats
  per_call = (usec1 - usec0).fdiv(calls1 - calls0)
  AlgoBench.print_rate("#{label}, inside Redis", [1_000_000 / per_call] * 2)
  printf("  %-52s %10.0f usec_per_call (evalsha)\n", '', per_call)
end

POOL.with { |c| c.call('FLUSHDB') }
begin
  tail!('KeepJob', 0, SIZE)
  Q.delete_by_class('NoSuchJob') # loads both scripts: the timed runs are EVALSHA hits
  Q.delete_job('no-such-jid')
  puts "wurk fast delete — queue of #{SIZE}, victims at the tail\n\n"

  run("fast delete_by_class (#{VICTIMS} of #{SIZE})", setup: -> { tail!('VictimJob', SIZE, VICTIMS) }) do
    removed = Q.delete_by_class('VictimJob')
    raise "delete_by_class removed #{removed}, not #{VICTIMS}" unless removed == VICTIMS
  end

  victim = format('%024x', SIZE + VICTIMS)
  run("fast delete_job (1 of #{SIZE})", setup: -> { tail!('VictimJob', SIZE + VICTIMS, 1) }) do
    raise 'delete_job found nothing' unless Q.delete_job(victim)
  end
  size = Q.size
  raise "queue holds #{size}, not #{SIZE}: a delete took a job it should not have" unless size == SIZE
ensure
  POOL.with { |c| c.call('FLUSHDB') }
end
