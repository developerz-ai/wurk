# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'base64'
require 'json'
require 'securerandom'
require 'stringio'
require 'zlib'

# Slice 07 — the HTTP API's observe plane: GET /stats, /queues, /queues/:name,
# /retries, /scheduled, /dead, /batches/:bid and the two pause toggles.
#
# The point of these routes is that they add no second reader over Redis, so
# the assertions run against state written by the canonical objects themselves
# (Wurk::Client, JobSet#schedule, Queue#pause!) and check that the HTTP answer
# is the one those objects give.
#
# Auth mechanics live in api_auth_test.rb and routing in api_app_test.rb; the
# scope checks here only pin which scope each route demands.
#
# Isolation: every test starts against a freshly flushed worker DB
# (RedisNamespace), and queue and class names still carry a per-instance
# namespace so nothing collides with a peer worker's fixtures.
class ApiQueuesTest < Wurk::Test::UnitCase
  parallelize_me!

  ADMIN_TOKEN = 'api-queues-admin-token-0123456789'
  READ_TOKEN = 'api-queues-read-token-0123456789'
  ENQUEUE_TOKEN = 'api-queues-enqueue-token-0123456789'

  def setup
    super
    @ns = "#{Process.pid}_#{object_id}"
    @queue = "q-#{@ns}"
    @other_queue = "q2-#{@ns}"
    @class_name = "ApiQueuesWorker#{@ns}"
    @pool = Wurk.configuration.redis_pool
  end

  # --- GET /stats --------------------------------------------------------

  def test_stats_reports_the_canonical_counters
    @pool.with { |conn| conn.call('MSET', 'stat:processed', '12', 'stat:failed', '3', 'stat:expired', '1') }
    enqueue(2)
    Wurk::ScheduledSet.new.schedule(Time.now.to_f + 60, job.merge('jid' => SecureRandom.hex(12)))
    Wurk::RetrySet.new.schedule(Time.now.to_f + 60, job.merge('jid' => SecureRandom.hex(12)))
    Wurk::DeadSet.new.schedule(Time.now.to_f, job.merge('jid' => SecureRandom.hex(12)))

    status, headers, body = get('/v1/stats')

    assert_equal 200, status
    assert_equal 'application/json', headers['content-type']
    assert_equal 12, body['processed']
    assert_equal 3, body['failed']
    assert_equal 1, body['expired']
    assert_equal 2, body['enqueued']
    assert_equal 1, body['scheduled']
    assert_equal 1, body['retries']
    assert_equal 1, body['dead']
    assert_equal 0, body['busy']
    assert_equal 0, body['processes']
  end

  # The same object the dashboard's stats endpoint reads, so the two can only
  # ever report the same numbers.
  def test_stats_agrees_with_the_inspector_it_reads
    enqueue(3)
    snapshot = Wurk::Stats.new
    _status, _headers, body = get('/v1/stats')

    assert_equal snapshot.enqueued, body['enqueued']
    assert_equal snapshot.queue_summaries.map(&:name).sort, body['queues'].map { |q| q['name'] }.sort
  end

  # `latency` beside a `queues` array would read as the fleet's; Stats measures
  # the `default` queue specifically, so the field says so.
  def test_stats_names_the_default_queue_latency_explicitly
    _status, _headers, body = get('/v1/stats')

    assert_in_delta 0.0, body['default_queue_latency'], 0.001
    refute body.key?('latency')
  end

  def test_stats_embeds_the_queue_summaries
    enqueue(1)
    _status, _headers, body = get('/v1/stats')
    summary = body['queues'].find { |q| q['name'] == @queue }

    assert_equal 1, summary['size']
    refute summary['paused']
  end

  # --- GET /queues -------------------------------------------------------

  def test_queues_lists_every_known_queue_largest_first
    enqueue(1)
    enqueue(3, queue: @other_queue)

    status, _headers, body = get('/v1/queues')

    assert_equal 200, status
    names = body['queues'].map { |q| q['name'] }
    sizes = body['queues'].map { |q| q['size'] }

    assert_equal [@other_queue, @queue], names
    assert_equal [3, 1], sizes
  end

  def test_queues_reports_the_paused_flag
    enqueue(1)
    Wurk::Queue.new(@queue).pause!

    _status, _headers, body = get('/v1/queues')

    assert body['queues'].find { |q| q['name'] == @queue }['paused']
  end

  def test_queues_is_empty_when_nothing_was_ever_enqueued
    _status, _headers, body = get('/v1/queues')

    assert_empty body['queues']
  end

  # --- GET /queues/:name -------------------------------------------------

  def test_queue_reports_depth_and_its_jobs
    jids = enqueue(2, args: [1])

    status, _headers, body = get("/v1/queues/#{@queue}")

    assert_equal 200, status
    assert_equal @queue, body['name']
    assert_equal 2, body['size']
    refute body['paused']
    rows = body['jobs']
    classes = rows.map { |j| j['class'] }
    args = rows.map { |j| j['args'] }
    queues = rows.map { |j| j['queue'] }

    assert_equal jids.sort, rows.map { |j| j['jid'] }.sort
    assert_equal [@class_name, @class_name], classes
    assert_equal [[1], [1]], args
    assert_equal [@queue, @queue], queues
  end

  # The display view, not the stored one: serving `record.args` here would put
  # the ciphertext envelope of every `encrypt: true` job on an HTTP response.
  def test_queue_job_rows_mask_an_encrypted_argument
    Wurk::Client.new.push(job('args' => ['plain', { 'wurk_encrypted' => 'ciphertext' }], 'encrypt' => true))

    _status, _headers, body = get("/v1/queues/#{@queue}")

    assert_equal ['plain', '<encrypted>'], body['jobs'].fetch(0)['args']
  end

  def test_queue_job_rows_carry_the_enqueue_timestamps
    enqueue(1)
    _status, _headers, body = get("/v1/queues/#{@queue}")
    row = body['jobs'].fetch(0)

    assert_in_delta Time.now.to_f, row['enqueued_at'], 30
    assert_in_delta Time.now.to_f, row['created_at'], 30
  end

  # A never-used name and a drained one are the same state in Redis, so both
  # answer with an empty queue rather than a 404 that only one of them earns.
  def test_queue_of_an_unknown_name_is_an_empty_queue
    status, _headers, body = get('/v1/queues/never-used')

    assert_equal 200, status
    assert_equal 0, body['size']
    assert_empty body['jobs']
  end

  # The router percent-decodes a captured segment, so a name containing '/'
  # is addressable — the same constraint config/routes.rb puts on the
  # dashboard's :name.
  def test_queue_name_may_be_percent_encoded
    slashed = "#{@queue}/sub"
    enqueue(1, queue: slashed)

    _status, _headers, body = get("/v1/queues/#{@queue}%2Fsub")

    assert_equal slashed, body['name']
    assert_equal 1, body['size']
  end

  def test_queue_rejects_a_name_carrying_whitespace
    status, headers, body = get('/v1/queues/two%20words')

    assert_equal 400, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'invalid_request', body['type']
  end

  def test_queue_rejects_an_oversized_name
    status, _headers, body = get("/v1/queues/#{'a' * 256}")

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  def test_queue_reports_being_paused
    enqueue(1)
    Wurk::Queue.new(@queue).pause!

    _status, _headers, body = get("/v1/queues/#{@queue}")

    assert body['paused']
  end

  # --- paging ------------------------------------------------------------

  def test_queue_pages_with_count_and_page
    enqueue(5)
    _status, _headers, first = get("/v1/queues/#{@queue}?count=2&page=0")
    _status, _headers, second = get("/v1/queues/#{@queue}?count=2&page=1")
    _status, _headers, last = get("/v1/queues/#{@queue}?count=2&page=2")

    assert_equal 2, first['jobs'].size
    assert_equal 2, second['jobs'].size
    assert_equal 1, last['jobs'].size
    assert_empty(first['jobs'].map { |j| j['jid'] } & second['jobs'].map { |j| j['jid'] })
  end

  def test_queue_page_defaults_to_the_first_twenty_five
    enqueue(1)
    _status, _headers, body = get("/v1/queues/#{@queue}")

    assert_equal 0, body['page']
    assert_equal 25, body['count']
  end

  # Out of range is a client asking for more than the API gives, not a client
  # bug — clamped, and echoed back so the clamp is visible.
  def test_queue_clamps_an_out_of_range_window
    enqueue(1)
    _status, _headers, body = get("/v1/queues/#{@queue}?count=9999&page=-4")

    assert_equal Wurk::API::Page::MAX_COUNT, body['count']
    assert_equal 0, body['page']
  end

  def test_queue_clamps_a_page_beyond_the_walk_bound
    _status, _headers, body = get("/v1/queues/#{@queue}?page=99999")

    assert_equal Wurk::API::Page::MAX_PAGE, body['page']
  end

  def test_queue_refuses_a_non_integer_page
    status, _headers, body = get("/v1/queues/#{@queue}?page=soon")

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_includes body['detail'], "'page'"
  end

  def test_queue_refuses_a_non_integer_count
    status, _headers, body = get("/v1/queues/#{@queue}?count=all")

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_includes body['detail'], "'count'"
  end

  # A repeated parameter is an ambiguous request, so it is answered rather
  # than silently resolved to one of the two values.
  def test_queue_refuses_a_repeated_paging_parameter
    status, _headers, body = get("/v1/queues/#{@queue}?count=1&count=2")

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  # Rack refuses a bad %-encoding before any paging value exists to clamp, and
  # that refusal is a 400 rather than the 500 the app's catch-all would make.
  def test_queue_refuses_a_malformed_query_string
    status, _headers, body = get("/v1/queues/#{@queue}?page=%")

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_includes body['detail'], 'query string'
  end

  def test_queue_ignores_an_empty_paging_parameter
    enqueue(1)
    status, _headers, body = get("/v1/queues/#{@queue}?page=&count=")

    assert_equal 200, status
    assert_equal 25, body['count']
  end

  # --- pause / unpause ---------------------------------------------------

  def test_pause_puts_the_queue_in_the_paused_set
    status, _headers, body = post("/v1/queues/#{@queue}/pause")

    assert_equal 200, status
    assert_equal @queue, body['name']
    assert body['paused']
    assert_predicate Wurk::Queue.new(@queue), :paused?
  end

  def test_unpause_takes_it_back_out
    Wurk::Queue.new(@queue).pause!
    status, _headers, body = post("/v1/queues/#{@queue}/unpause")

    assert_equal 200, status
    refute body['paused']
    refute_predicate Wurk::Queue.new(@queue), :paused?
  end

  def test_pause_is_idempotent
    post("/v1/queues/#{@queue}/pause")
    status, _headers, body = post("/v1/queues/#{@queue}/pause")

    assert_equal 200, status
    assert body['paused']
  end

  def test_pause_rejects_a_malformed_queue_name
    status, _headers, body = post('/v1/queues/two%20words/pause')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  def test_pause_answers_post_only
    status, headers, = call(env_for('GET', "/v1/queues/#{@queue}/pause"))

    assert_equal 405, status
    assert_equal 'POST', headers['allow']
  end

  # --- GET /retries /scheduled /dead -------------------------------------

  def test_retries_lists_the_retry_set_newest_first
    older = seed(Wurk::RetrySet.new, Time.now.to_f + 60)
    newer = seed(Wurk::RetrySet.new, Time.now.to_f + 600)

    status, _headers, body = get('/v1/retries')

    assert_equal 200, status
    assert_equal 'retry', body['name']
    assert_equal 2, body['total']
    assert_equal [newer, older], jids(body)
  end

  def test_scheduled_lists_the_schedule_set
    jid = seed(Wurk::ScheduledSet.new, Time.now.to_f + 60)

    _status, _headers, body = get('/v1/scheduled')

    assert_equal 'schedule', body['name']
    assert_equal [jid], jids(body)
  end

  def test_dead_lists_the_dead_set
    jid = seed(Wurk::DeadSet.new, Time.now.to_f)

    _status, _headers, body = get('/v1/dead')

    assert_equal 'dead', body['name']
    assert_equal [jid], jids(body)
  end

  # `at` is the member's ZSET score in epoch seconds — the one timestamp the
  # contract ships, rather than the score and a duplicate of it.
  def test_sorted_entries_report_the_score_as_at
    at = Time.now.to_f + 900
    seed(Wurk::RetrySet.new, at)

    _status, _headers, body = get('/v1/retries')

    assert_in_delta at, body['jobs'].fetch(0)['at'], 0.001
  end

  def test_sorted_entries_report_the_failure_that_put_them_there
    backtrace = ['lib/foo.rb:1', 'lib/bar.rb:42']
    seed(
      Wurk::RetrySet.new, Time.now.to_f + 60,
      'error_class' => 'RuntimeError', 'error_message' => 'boom', 'retry_count' => 2,
      'failed_at' => 1_700_000_000.5, 'retried_at' => 1_700_000_100.5,
      'error_backtrace' => Base64.encode64(Zlib.deflate(Wurk.dump_json(backtrace)))
    )

    _status, _headers, body = get('/v1/retries')
    row = body['jobs'].fetch(0)

    assert_equal 'RuntimeError', row['error_class']
    assert_equal 'boom', row['error_message']
    assert_equal 2, row['retry_count']
    assert_in_delta 1_700_000_000.5, row['failed_at'], 0.001
    assert_in_delta 1_700_000_100.5, row['retried_at'], 0.001
    assert_equal backtrace, row['error_backtrace']
  end

  # A row that never failed says so with nulls rather than empty strings — the
  # dashboard's `.to_s` is a rendering choice a machine client should not
  # inherit.
  def test_sorted_entries_leave_absent_failure_fields_null
    seed(Wurk::ScheduledSet.new, Time.now.to_f + 60)

    _status, _headers, body = get('/v1/scheduled')
    row = body['jobs'].fetch(0)

    assert_nil row['error_class']
    assert_nil row['retry_count']
    assert_nil row['failed_at']
    assert_nil row['retried_at']
    assert_nil row['error_backtrace']
  end

  def test_sorted_sets_page_like_queues_do
    3.times { |i| seed(Wurk::RetrySet.new, Time.now.to_f + (60 * (i + 1))) }

    _status, _headers, body = get('/v1/retries?count=1&page=1')

    assert_equal 3, body['total']
    assert_equal 1, body['page']
    assert_equal 1, body['jobs'].size
  end

  def test_sorted_sets_refuse_a_malformed_window
    status, _headers, body = get('/v1/retries?count=lots')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  # --- GET /batches/:bid -------------------------------------------------

  def test_batch_reports_the_status_data
    bid = seed_batch(total: 5, pending: 2, failures: 1, live_jids: %w[jid-a jid-b])

    status, _headers, body = get("/v1/batches/#{bid}")

    assert_equal 200, status
    assert_equal bid, body['bid']
    assert_equal 5, body['total']
    assert_equal 2, body['pending']
    assert_equal 1, body['failures']
    refute body['complete']
  end

  def test_batch_agrees_with_the_inspector_it_reads
    bid = seed_batch(total: 1, pending: 0, description: 'nightly')
    _status, _headers, body = get("/v1/batches/#{bid}")

    assert_equal Wurk::Batch::Status.new(bid).data, body
  end

  def test_batch_of_an_unknown_bid_is_a_batch_not_found_problem
    bid = SecureRandom.urlsafe_base64(10)
    status, headers, body = get("/v1/batches/#{bid}")

    assert_equal 404, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'batch_not_found', body['type']
    assert_equal 'Batch Not Found', body['title']
    assert_equal bid, body['bid']
  end

  def test_batch_rejects_a_bid_that_is_not_url_safe
    status, _headers, body = get('/v1/batches/%2A')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_includes body['detail'], 'batch id'
  end

  # --- scopes ------------------------------------------------------------

  def test_read_scope_may_observe
    %w[/v1/stats /v1/queues /v1/retries /v1/scheduled /v1/dead].each do |path|
      status, = get(path, token: READ_TOKEN)

      assert_equal 200, status, path
    end
  end

  def test_enqueue_scope_may_not_observe
    status, _headers, body = get('/v1/stats', token: ENQUEUE_TOKEN)

    assert_equal 403, status
    assert_equal 'insufficient_scope', body['type']
    assert_equal 'read', body['required_scope']
  end

  # Pausing `default` stops the fleet without enqueueing or deleting anything,
  # so it sits with the destructive routes rather than the listings.
  def test_read_scope_may_not_pause
    status, _headers, body = post("/v1/queues/#{@queue}/pause", token: READ_TOKEN)

    assert_equal 403, status
    assert_equal 'admin', body['required_scope']
    refute_predicate Wurk::Queue.new(@queue), :paused?
  end

  def test_read_scope_may_not_unpause
    Wurk::Queue.new(@queue).pause!
    status, _headers, body = post("/v1/queues/#{@queue}/unpause", token: READ_TOKEN)

    assert_equal 403, status
    assert_equal 'admin', body['required_scope']
    assert_predicate Wurk::Queue.new(@queue), :paused?
  end

  private

  def app = @app ||= Wurk::API::App.new(config: config)

  def config
    @config ||= Wurk::Configuration.new.tap do |cfg|
      cfg.api_token(ADMIN_TOKEN, scopes: %i[admin])
      cfg.api_token(READ_TOKEN, scopes: %i[read])
      cfg.api_token(ENQUEUE_TOKEN, scopes: %i[enqueue])
    end
  end

  def job(**overrides)
    { 'class' => @class_name, 'args' => [], 'queue' => @queue }.merge(overrides.transform_keys(&:to_s))
  end

  # Enqueues through the client, so the `queues` SET membership, the payload
  # shape and the timestamps are all the ones a Ruby producer would write.
  def enqueue(count, queue: @queue, args: [])
    Array.new(count) { Wurk::Client.new.push(job('queue' => queue, 'args' => args)) }
  end

  def seed(set, at, fields = {})
    jid = SecureRandom.hex(12)
    set.schedule(at, job.merge('jid' => jid).merge(fields))
    jid
  end

  # `live_jids` seeds `b-<bid>-jids`, which Batch::Status recomputes
  # completeness from when the hash carries no `complete` flag yet.
  def seed_batch(live_jids: [], **fields)
    bid = SecureRandom.urlsafe_base64(10)
    row = { 'created_at' => Time.now.to_f.to_s, 'tags' => '[]' }.merge(fields.transform_keys(&:to_s))
    @pool.with do |conn|
      conn.call('HSET', "b-#{bid}", *row.flatten.map(&:to_s))
      conn.call('SADD', "b-#{bid}-jids", *live_jids) if live_jids.any?
    end
    bid
  end

  def jids(body) = body['jobs'].map { |job| job['jid'] }

  def call(env) = app.call(env)

  def get(path, token: ADMIN_TOKEN) = request('GET', path, token: token)
  def post(path, token: ADMIN_TOKEN) = request('POST', path, token: token)

  def request(method, path, token:)
    info, _, query = path.partition('?')
    parse(call(env_for(method, info, query: query, token: token)))
  end

  def parse(response)
    status, headers, body = response
    [status, headers, JSON.parse(body.join)]
  end

  def env_for(method, path, query: '', token: ADMIN_TOKEN)
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => '',
      'QUERY_STRING' => query,
      'rack.input' => StringIO.new,
      'rack.errors' => StringIO.new,
      'HTTP_AUTHORIZATION' => "Bearer #{token}"
    }
  end
end
