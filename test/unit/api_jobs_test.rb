# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'json'
require 'securerandom'
require 'stringio'

# Slice 07 — the HTTP API's produce plane: POST /jobs, POST /jobs/bulk,
# DELETE /jobs/:jid. Every enqueue runs through Wurk::Client against real
# Redis, and the assertions are on what actually landed there rather than on
# the response alone — the point of these routes is that they add no second
# way to write a job.
#
# Auth mechanics live in api_auth_test.rb and routing in api_app_test.rb; the
# scope checks here only pin which scope each of these three routes demands.
#
# Parallel safety: queue and class names carry a per-instance namespace, and
# the worker's Redis DB is flushed after every test (RedisNamespace).
class ApiJobsTest < Wurk::Test::UnitCase
  parallelize_me!

  ADMIN_TOKEN = 'api-jobs-admin-token-0123456789'
  ENQUEUE_TOKEN = 'api-jobs-enqueue-token-0123456789'
  READ_TOKEN = 'api-jobs-read-token-0123456789'

  JID_PATTERN = /\A[0-9a-f]{24}\z/

  # Adds a field no route knows about, so its presence on the stored payload
  # proves the client's chain ran rather than something here assembling a hash.
  StampMiddleware = Class.new do
    include Wurk::Middleware::ClientMiddleware

    def call(_job_class, job, _queue, _pool)
      job['api_jobs_stamp'] = 'stamped'
      yield
    end
  end

  # A halting middleware — what `collapse:`/`unique_for:` do to a duplicate.
  HaltMiddleware = Class.new do
    include Wurk::Middleware::ClientMiddleware

    def call(*) = nil
  end

  def setup
    super
    @ns = "#{Process.pid}-#{object_id}"
    @queue = "q-#{@ns}"
    @class_name = "ApiJobsWorker@#{@ns}"
    @pool = Wurk.configuration.redis_pool
  end

  # --- POST /jobs --------------------------------------------------------

  def test_post_jobs_enqueues_the_body_verbatim
    status, headers, body = post('/v1/jobs', job(args: [1, 'two']))

    assert_equal 201, status
    assert_equal 'application/json', headers['content-type']
    assert_match JID_PATTERN, body['jid']

    payload = queued_payloads.fetch(0)

    assert_equal @class_name, payload['class']
    assert_equal [1, 'two'], payload['args']
    assert_equal @queue, payload['queue']
    assert_equal body['jid'], payload['jid']
  end

  # The pillar-1 check at this layer: the payload came out of Wurk::Client, so
  # a field only its middleware chain can add is on the stored job.
  def test_post_jobs_payload_is_built_by_the_client_chain
    with_client_middleware(StampMiddleware) { post('/v1/jobs', job) }

    assert_equal 'stamped', queued_payloads.fetch(0)['api_jobs_stamp']
  end

  def test_post_jobs_carries_the_options_the_body_sets
    post('/v1/jobs', job(retry: 5))

    assert_equal 5, queued_payloads.fetch(0)['retry']
  end

  def test_post_jobs_with_at_schedules_instead_of_queueing
    at = Time.now.to_f + 3600
    _status, _headers, body = post('/v1/jobs', job(at: at))

    entry = Wurk::ScheduledSet.new.find_job(body['jid'])

    refute_nil entry
    assert_in_delta at, entry.score, 0.001
    assert_empty queued_payloads
  end

  # A push the chain dropped is the producer's own policy working, not a
  # failure — so 200 with a null jid, not a 4xx.
  def test_post_jobs_reports_a_middleware_halt_without_a_jid
    status, _headers, body = with_client_middleware(HaltMiddleware) { post('/v1/jobs', job) }

    assert_equal 200, status
    assert_nil body['jid']
    assert_empty queued_payloads
  end

  def test_post_jobs_rejects_a_body_that_is_not_json
    status, headers, body = post_raw('/v1/jobs', 'not json')

    assert_equal 400, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'invalid_request', body['type']
    assert_equal 'Invalid Request', body['title']
    assert_equal 'The request body is not valid JSON.', body['detail']
  end

  # A parser message quotes the unparsed remainder of the document; a 10 MB
  # malformed body must not come back as a 10 MB error.
  def test_a_malformed_body_is_not_echoed_back
    _status, _headers, body = post_raw('/v1/jobs', %({"class": "#{'z' * 400}))

    refute_includes JSON.generate(body), 'zzzz'
  end

  def test_post_jobs_rejects_a_json_body_that_is_not_an_object
    status, _headers, body = post_raw('/v1/jobs', '[1, 2]')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_equal 'The request body must be a JSON object.', body['detail']
  end

  def test_post_jobs_rejects_an_empty_body
    status, _headers, body = post_raw('/v1/jobs', '')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  # Rack 3.1 made `rack.input` optional, so a server may hand the app an env
  # with no body stream at all. That is a bodyless request, not a crash.
  def test_post_jobs_without_a_body_stream_is_a_bodyless_request
    env = env_for('POST', '/v1/jobs')
    env.delete('rack.input')
    status, _headers, body = parse(call(env))

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  # Client owns what a valid job hash is; the route surfaces its verdict rather
  # than duplicating it.
  def test_post_jobs_surfaces_client_validation_as_a_problem
    status, _headers, body = post('/v1/jobs', { 'class' => @class_name })

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_includes body['detail'], "'class' and 'args'"
    assert_empty queued_payloads
  end

  def test_post_jobs_rejects_a_non_numeric_at
    status, _headers, body = post('/v1/jobs', job(at: 'soon'))

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  def test_jobs_answers_post_only
    status, headers, = call(env_for('GET', '/v1/jobs'))

    assert_equal 405, status
    assert_equal 'POST', headers['allow']
  end

  # --- POST /jobs/bulk ---------------------------------------------------

  def test_post_bulk_enqueues_every_arg_set
    status, _headers, body = post('/v1/jobs/bulk', job(args: [[1], [2], [3]]))

    assert_equal 201, status
    assert_equal 3, body['jids'].size
    body['jids'].each { |jid| assert_match JID_PATTERN, jid }
    assert_equal [[1], [2], [3]], queued_payloads.map { |p| p['args'] }.sort_by(&:first)
  end

  def test_post_bulk_jids_match_the_stored_payloads
    _status, _headers, body = post('/v1/jobs/bulk', job(args: [[1], [2]]))

    assert_equal body['jids'].sort, queued_payloads.map { |p| p['jid'] }.sort
  end

  def test_post_bulk_with_no_args_enqueues_nothing
    status, _headers, body = post('/v1/jobs/bulk', job)

    assert_equal 200, status
    assert_empty body['jids']
    assert_empty queued_payloads
  end

  def test_post_bulk_marks_halted_jobs_positionally
    status, _headers, body = with_client_middleware(HaltMiddleware) do
      post('/v1/jobs/bulk', job(args: [[1], [2]]))
    end

    assert_equal 200, status
    assert_equal [nil, nil], body['jids']
    assert_empty queued_payloads
  end

  def test_post_bulk_rejects_a_malformed_arg_shape
    status, _headers, body = post('/v1/jobs/bulk', job(args: [1, 2]))

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_includes body['detail'], 'Array of Arrays'
  end

  def test_post_bulk_schedules_when_at_is_given
    _status, _headers, body = post('/v1/jobs/bulk', job(args: [[1], [2]], at: Time.now.to_f + 600))

    assert_empty queued_payloads
    body['jids'].each { |jid| refute_nil Wurk::ScheduledSet.new.find_job(jid) }
  end

  # --- DELETE /jobs/:jid -------------------------------------------------

  def test_delete_removes_a_scheduled_job
    jid = schedule_into(Wurk::ScheduledSet.new)
    status, _headers, body = delete("/v1/jobs/#{jid}")

    assert_equal 200, status
    assert_equal jid, body['jid']
    assert_equal 'schedule', body['set']
    assert_nil Wurk::ScheduledSet.new.find_job(jid)
  end

  def test_delete_removes_a_retrying_job
    jid = schedule_into(Wurk::RetrySet.new)
    status, _headers, body = delete("/v1/jobs/#{jid}")

    assert_equal 200, status
    assert_equal 'retry', body['set']
    assert_nil Wurk::RetrySet.new.find_job(jid)
  end

  # Removing a dead job is an operator action against a different set, so this
  # route leaves it alone rather than quietly widening its own reach.
  def test_delete_leaves_the_dead_set_alone
    jid = schedule_into(Wurk::DeadSet.new)
    status, _headers, body = delete("/v1/jobs/#{jid}")

    assert_equal 404, status
    assert_equal 'job_not_found', body['type']
    refute_nil Wurk::DeadSet.new.find_job(jid)
  end

  def test_delete_of_an_unknown_jid_is_a_job_not_found_problem
    jid = SecureRandom.hex(12)
    status, headers, body = delete("/v1/jobs/#{jid}")

    assert_equal 404, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'job_not_found', body['type']
    assert_equal 'Job Not Found', body['title']
    assert_equal jid, body['jid']
  end

  # find_job feeds the jid to ZSCAN as a glob, so a metacharacter never gets
  # that far — decoded, because the router unescapes captures.
  def test_delete_rejects_a_jid_that_is_not_url_safe
    status, _headers, body = delete('/v1/jobs/%2A')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  def test_delete_rejects_an_oversized_jid
    status, _headers, body = delete("/v1/jobs/#{'a' * 256}")

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  # --- Scopes ------------------------------------------------------------

  def test_enqueue_scope_may_produce
    status, = post('/v1/jobs', job, token: ENQUEUE_TOKEN)

    assert_equal 201, status
  end

  def test_read_scope_may_not_produce
    status, _headers, body = post('/v1/jobs', job, token: READ_TOKEN)

    assert_equal 403, status
    assert_equal 'insufficient_scope', body['type']
    assert_equal 'enqueue', body['required_scope']
    assert_empty queued_payloads
  end

  def test_read_scope_may_not_bulk_produce
    status, _headers, body = post('/v1/jobs/bulk', job(args: [[1]]), token: READ_TOKEN)

    assert_equal 403, status
    assert_equal 'enqueue', body['required_scope']
  end

  # A jid is not bound to the token that produced it, so cancelling one is an
  # admin action — an enqueue-scoped producer holding it could walk the whole
  # retry set.
  def test_enqueue_scope_may_not_delete
    jid = schedule_into(Wurk::ScheduledSet.new)
    status, _headers, body = delete("/v1/jobs/#{jid}", token: ENQUEUE_TOKEN)

    assert_equal 403, status
    assert_equal 'insufficient_scope', body['type']
    assert_equal 'admin', body['required_scope']
    refute_nil Wurk::ScheduledSet.new.find_job(jid)
  end

  private

  def app = @app ||= Wurk::API::App.new(config: config)

  def config
    @config ||= Wurk::Configuration.new.tap do |cfg|
      cfg.api_token(ADMIN_TOKEN, scopes: %i[admin])
      cfg.api_token(ENQUEUE_TOKEN, scopes: %i[enqueue])
      cfg.api_token(READ_TOKEN, scopes: %i[read])
    end
  end

  # The Sidekiq job hash the produce routes take, namespaced to this test.
  def job(**overrides)
    { 'class' => @class_name, 'args' => [], 'queue' => @queue }.merge(overrides.transform_keys(&:to_s))
  end

  def queued_payloads
    @pool.with { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |raw| JSON.parse(raw) }
  end

  # Puts a job into a sorted set the way the retrier and scheduler do — through
  # JobSet#schedule — and hands back its jid.
  def schedule_into(set)
    jid = SecureRandom.hex(12)
    set.schedule(Time.now.to_f + 3600, job.merge('jid' => jid))
    jid
  end

  # Wurk::Client resolves the chain off the process-wide configuration at push
  # time — the same one a Ruby producer in this process uses — so mutating it
  # takes the suite-wide global-state mutex.
  def with_client_middleware(klass)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      Wurk.configuration.client_middleware.add(klass)
      yield
    ensure
      Wurk.configuration.client_middleware.remove(klass)
    end
  end

  def call(env) = app.call(env)

  def post(path, payload, token: ADMIN_TOKEN) = post_raw(path, JSON.generate(payload), token: token)

  def post_raw(path, raw, token: ADMIN_TOKEN)
    parse(call(env_for('POST', path, body: raw, token: token)))
  end

  def delete(path, token: ADMIN_TOKEN) = parse(call(env_for('DELETE', path, token: token)))

  def parse(response)
    status, headers, body = response
    [status, headers, JSON.parse(body.join)]
  end

  def env_for(method, path, body: '', token: ADMIN_TOKEN)
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => '',
      'QUERY_STRING' => '',
      'CONTENT_TYPE' => 'application/json',
      'CONTENT_LENGTH' => body.bytesize.to_s,
      'HTTP_AUTHORIZATION' => "Bearer #{token}",
      'rack.input' => StringIO.new(body),
      'rack.errors' => StringIO.new
    }
  end
end
