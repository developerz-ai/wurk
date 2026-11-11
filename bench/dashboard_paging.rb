# frozen_string_literal: true

# What a dashboard page costs, page 0 against the deepest page the API serves
# (Api::Pagination::MAX_PAGE - 1 = 999), for every paged list: queue, dead,
# batches, flows, limits. Rows 07-A1/A2/A6/A16 of docs/plans/2026/11/10/101-
# evidence-driven-improvement-sweep/07-algorithms.md. Then the round trips of the
# polled read endpoints, rows K1/K2/K3/K5 of 21-counters-and-read-caching.md
# (and 07-A14: the SSE tick builds the same payload as /api/stats).
#
# Requests go through the real engine (the dummy Rails app, Rack::MockRequest),
# so a count is everything the controller, serializers and data views issue.
# Counts are deterministic and checked against BUDGETS (exit 1 when one is
# exceeded); a fix that lowers a count lowers its budget in the same change.
# Rates are advisory.
#
#   eval "$(bin/redis env algobench)"
#   bundle exec ruby -Ilib bench/dashboard_paging.rb
#
# WURK_BENCH_PAGE_SIZE (default 25, the SPA's page) sets ?count=; every list is
# seeded one page past page 999, so page 999 is full. 200 (MAX_PAGE_SIZE) is
# the plan's worst case: eight times the rows, about a minute to seed.
# Dedicated logical DB (default 1), FLUSHDB'd before and after. Never DB 0.

ENV['RAILS_ENV'] ||= 'test'
ENV['WURK_DISABLED'] = '1'

require 'logger'
require 'json'
require 'zlib'
require_relative 'algo/support'
require_relative '../test/dummy/config/environment'
require 'rack/mock'

PAGE_SIZE = Integer(ENV.fetch('WURK_BENCH_PAGE_SIZE', '25'))
DEEP_PAGE = Wurk::Api::Pagination::MAX_PAGE - 1
ROWS      = PAGE_SIZE * (DEEP_PAGE + 1)
# Failed jids per batch on page 0 (07-A2: the list carries every one of them).
FAILED_PER_BATCH = Integer(ENV.fetch('WURK_BENCH_FAILED_PER_BATCH', '1000'))
QUEUE = 'paging'

# [round trips, commands] at the default shape (25 per page, 1000 failed jids
# per batch). Exact, so any added round trip or command fails the run; a fix
# lowers its row in the same change. Another shape prints counts ungated.
#
# Before 07-A1/A2/A6/A14/A16 and 21-K1..K5 (v1.13.0): queue page 0/999 5/1003,
# dead 2/501, batches 52/25,276, flows 27/25,251, limits 150/150, SSE tick 9,
# /api/queues 6, /api/processes 6, queue detail 5 round trips; 25,000 failed
# jids and 25 inflated backtraces in the page-0 payloads.
#
# Limits: page 0 runs first and pays the per-process liveness probe (an EXISTS
# per limiter, at most once a minute); page 999 is a page between probes. The
# rest of a limits row is Limiter#status, three round trips per row.
# /api/queues is one command over its old count: the snapshot also reads the
# `default` tail the landing payload needs.
BUDGETS = {
  'queue page 0' => [1, 4], 'queue page 999' => [1, 4],
  'dead page 0' => [1, 2], 'dead page 999' => [1, 2],
  'batches page 0' => [2, 127], 'batches page 999' => [2, 127],
  'flows page 0' => [2, 27], 'flows page 999' => [2, 27],
  'limits page 0' => [126, 25_102], 'limits page 999' => [77, 101],
  'GET /api/stats (SSE tick), 10 queues 5 processes' => [2, 36],
  'GET /api/stats (SSE tick), 20 queues 10 processes' => [2, 61],
  'GET /api/queues, 10 queues 5 processes' => [2, 36],
  'GET /api/queues, 20 queues 10 processes' => [2, 61],
  'GET /api/queues/:name, page 0' => [1, 4],
  'GET /api/processes, 5 processes' => [5, 14],
  'GET /api/processes, 10 processes' => [5, 24]
}.freeze
# Payload rows, not round trips: list rows carry neither jid arrays (A2) nor
# backtraces (A16).
PAYLOAD_BUDGETS = {
  'batches page 0 failed_jids in payload' => 0,
  'dead page 0 rows inflating error_backtrace' => 0
}.freeze
# Ruby objects one page request allocates, Rails stack included (08-M9: the
# memory budget of a dashboard request), measured on a second request so lazy
# loads are not in it. About 25% over the count measured on Ruby 3.4.2 (in
# the comment per row), since the exact number moves with the Ruby and Rails
# versions. A page that walked its whole list would be orders of magnitude over.
ALLOC_BUDGETS = {
  'queue page 0' => 1_700, 'queue page 999' => 1_700,        # 1,337 / 1,335
  'dead page 0' => 1_950, 'dead page 999' => 1_950,          # 1,556 / 1,557
  'batches page 0' => 3_950, 'batches page 999' => 3_950,    # 3,152 / 3,153
  'flows page 0' => 1_950, 'flows page 999' => 1_950,        # 1,540 / 1,541
  'limits page 0' => 37_000, 'limits page 999' => 37_000     # 29,645 / 29,648
}.freeze
GATED = PAGE_SIZE == 25 && FAILED_PER_BATCH == 1000

Wurk.configuration.logger = Logger.new(IO::NULL)
Wurk.configuration.redis = AlgoBench.redis_options('1')
POOL = AlgoBench.check_pool!(Wurk.configuration.redis_pool)
APP = Rack::MockRequest.new(Rails.application)

def get(path)
  response = APP.get(path, 'HTTP_HOST' => 'localhost')
  raise "GET #{path} answered #{response.status}: #{response.body[0, 300]}" unless response.status == 200

  response.body
end

def job(index, klass = 'PagingJob')
  { 'class' => klass, 'args' => [index], 'queue' => QUEUE, 'jid' => format('%024x', index),
    'created_at' => 1_700_000_000.0, 'enqueued_at' => 1_700_000_000.0, 'retry' => true }
end

BACKTRACE = [Zlib::Deflate.deflate(JSON.dump(Array.new(20) { |i| "app/jobs/paging_job.rb:#{i}:in 'perform'" }))]
            .pack('m0')

def dead_job(index)
  job(index).merge('error_class' => 'RuntimeError', 'error_message' => 'boom', 'retry_count' => 25,
                   'failed_at' => 1_700_000_000.0, 'error_backtrace' => BACKTRACE)
end

def seed_lists
  rows = Array.new(ROWS) { |i| ['LPUSH', "queue:#{QUEUE}", JSON.dump(job(i))] }
  rows << ['SADD', 'queues', QUEUE]
  rows.concat(Array.new(ROWS) { |i| ['ZADD', 'dead', (1_700_000_000 + i).to_s, JSON.dump(dead_job(i))] })
  rows.concat(Array.new(ROWS) { |i| batch_rows(i) }.flatten(1))
  rows.concat(Array.new(ROWS) { |i| flow_rows(i) }.flatten(1))
  AlgoBench.seed(POOL, rows)
  seed_failed_jids
  seed_limiters
end

def batch_rows(index)
  bid = format('b%07d', index)
  [['ZADD', 'batches', index.to_s, bid],
   ['HSET', "b-#{bid}", 'total', '10', 'pending', '2', 'failures', '1', 'created_at', '1700000000.0',
    'description', "batch #{index}"]]
end

def flow_rows(index)
  fid = format('f%07d', index)
  [['ZADD', Wurk::Keys::FLOWS_SET, index.to_s, fid],
   ['HSET', Wurk::Keys.flow(fid), 'state', 'running', 'total', '4', 'pending', '2', 'depth', '2', 'width', '2',
    'created_at', '1700000000.0']]
end

# The newest PAGE_SIZE batches (page 0, ZRANGE REV) each carry FAILED_PER_BATCH
# failed jids.
def seed_failed_jids
  rows = ((ROWS - PAGE_SIZE)...ROWS).flat_map do |i|
    jids = Array.new(FAILED_PER_BATCH) { |j| format('%012x%012x', i, j) }
    jids.each_slice(1000).map { |slice| ['SADD', "b-#{format('b%07d', i)}-failed", *slice] }
  end
  AlgoBench.seed(POOL, rows, slice: 100)
end

# One real registration for the metadata shape, copied to ROWS names.
def seed_limiters
  Wurk::Limiter.concurrent('paging-proto', 5)
  proto = POOL.with { |c| c.call('HGETALL', 'lmtr:paging-proto') }
  proto = proto.each_slice(2).to_h if proto.is_a?(Array)
  rows = Array.new(ROWS) do |i|
    name = format('paging-%07d', i)
    [['SADD', Wurk::Limiter::LIST_KEY, name], ['HSET', "lmtr:#{name}", *proto.merge('name' => name).flatten]]
  end
  AlgoBench.seed(POOL, rows.flatten(1))
end

LISTS = {
  'queue' => "/wurk/api/queues/#{QUEUE}",
  'dead' => '/wurk/api/dead',
  'batches' => '/wurk/api/batches',
  'flows' => '/wurk/api/flows',
  'limits' => '/wurk/api/limiters'
}.freeze

def paged(path, page) = "#{path}?page=#{page}&count=#{PAGE_SIZE}"

def page_costs
  puts "\n== paging: page 0 vs page #{DEEP_PAGE}, ?count=#{PAGE_SIZE}, #{ROWS} rows per list"
  LISTS.each do |name, path|
    [0, DEEP_PAGE].each do |page|
      body = nil
      cost = AlgoBench.count { body = get(paged(path, page)) }
      rows = JSON.parse(body).values_at('jobs', 'entries', 'batches', 'flows', 'limiters').compact.first
      raise "#{name} page #{page} served #{rows.size} rows, not #{PAGE_SIZE}" unless rows.size == PAGE_SIZE

      label = "#{name} page #{page}"
      AlgoBench.print_count(label, cost)
      AlgoBench.budget_count!(label, cost, BUDGETS.fetch(label)) if GATED
      page_allocations(label, paged(path, page))
    end
  end
end

def page_allocations(label, path)
  get(path)
  before = GC.stat(:total_allocated_objects)
  get(path)
  allocated = GC.stat(:total_allocated_objects) - before
  printf("  %-52s %10d objects allocated\n", '', allocated)
  AlgoBench.budget!("#{label} (allocations)", allocated, ALLOC_BUDGETS.fetch(label)) if GATED
end

def payload_costs
  puts "\n== list payloads (07-A2, A16)"
  batches = JSON.parse(get(paged(LISTS['batches'], 0)))['batches']
  jids = batches.sum { |row| Array(row['failed_jids']).size }
  bytes = get(paged(LISTS['batches'], 0)).bytesize
  printf("  %-52s %10d jids, %d bytes\n", 'batches page 0 failed_jids', jids, bytes)
  label = 'batches page 0 failed_jids in payload'
  AlgoBench.budget!(label, jids, PAYLOAD_BUDGETS.fetch(label)) if GATED

  entries = JSON.parse(get(paged(LISTS['dead'], 0)))['entries']
  inflated = entries.count { |row| row['error_backtrace'] }
  label = 'dead page 0 rows inflating error_backtrace'
  printf("  %-52s %10d of %d rows\n", label, inflated, entries.size)
  AlgoBench.budget!(label, inflated, PAYLOAD_BUDGETS.fetch(label)) if GATED
end

def page_rates
  puts "\n== paging rates (advisory)"
  LISTS.each do |name, path|
    [0, DEEP_PAGE].each do |page|
      AlgoBench.timed("dashboard #{name} page #{page} (count #{PAGE_SIZE})", time: page.zero? ? 2 : 4, min: 2) do
        get(paged(path, page))
      end
    end
  end
end

# K1-K5 fixtures: `queues` queues of 3 jobs each, `processes` live heartbeats.
def seed_read_fixture(queues, processes)
  POOL.with { |c| c.call('FLUSHDB') }
  now = Time.now.to_f
  rows = Array.new(queues) do |q|
    jobs = Array.new(3) { |i| ['LPUSH', "queue:q#{q}", JSON.dump(job(i).merge('queue' => "q#{q}"))] }
    [['SADD', 'queues', "q#{q}"], *jobs]
  end.flatten(1)
  processes.times do |p|
    identity = "host#{p}:#{1000 + p}:nonce#{p}"
    info = { 'hostname' => "host#{p}", 'started_at' => now, 'pid' => 1000 + p, 'tag' => 'app', 'concurrency' => 5,
             'queues' => Array.new(queues) { |q| "q#{q}" }, 'labels' => [], 'identity' => identity,
             'version' => Wurk::VERSION, 'embedded' => false }
    rows << ['SADD', 'processes', identity]
    rows << ['HSET', identity, 'info', JSON.dump(info), 'concurrency', '5', 'busy', '0', 'beat', now.to_s,
             'quiet', 'false', 'rss', '1000', 'rtt_us', '100']
  end
  rows << %w[SET dear-leader host0:1000:nonce0]
  AlgoBench.seed(POOL, rows)
end

def read_costs
  puts "\n== polled reads (21-K1..K5, 07-A14)"
  [[10, 5], [20, 10]].each do |queues, processes|
    seed_read_fixture(queues, processes)
    get('/wurk/api/stats') # warm the pool: the connection prelude is not the endpoint's
    {
      "GET /api/stats (SSE tick), #{queues} queues #{processes} processes" => '/wurk/api/stats',
      "GET /api/queues, #{queues} queues #{processes} processes" => '/wurk/api/queues',
      "GET /api/processes, #{processes} processes" => '/wurk/api/processes'
    }.each { |label, path| read_cost(label, path) }
  end
  read_cost('GET /api/queues/:name, page 0', '/wurk/api/queues/q0?page=0')
end

def read_cost(label, path)
  cost = AlgoBench.count { get(path) }
  AlgoBench.print_count(label, cost)
  AlgoBench.budget_count!(label, cost, BUDGETS.fetch(label))
end

POOL.with { |c| c.call('FLUSHDB') }
t0 = AlgoBench.monotonic
seed_lists
get('/wurk/api/stats')
puts format('seeded %d rows x 5 lists in %.1fs', ROWS, AlgoBench.monotonic - t0)
begin
  page_costs
  payload_costs
  page_rates
  read_costs
ensure
  POOL.with { |c| c.call('FLUSHDB') }
end
AlgoBench.finish!
