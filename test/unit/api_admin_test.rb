# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'json'
require 'securerandom'
require 'stringio'

# Plan 101 slice 10 A3 and slice 07 A17: the operator actions on /v1
# (retry one retrying or dead job, clear a queue), the batch listing, and the
# `?score=` lookup that turns a jid search from a ZSCAN into one ZRANGEBYSCORE.
#
# State is written by the canonical objects (Client, JobSet#schedule) and read
# back through them, so these pin the HTTP answer to what those objects do.
class ApiAdminTest < Wurk::Test::UnitCase
  parallelize_me!

  ADMIN_TOKEN = 'api-admin-admin-token-0123456789'
  READ_TOKEN = 'api-admin-read-token-0123456789'

  # A set that fails the test the moment anything scans it.
  class UnscannableSet < Wurk::ScheduledSet
    def find_job(_jid) = raise('a score-addressed lookup must not ZSCAN')
  end

  def setup
    super
    @ns = "#{Process.pid}_#{object_id}"
    @queue = "q-#{@ns}"
  end

  # --- POST /retries/:jid/retry --------------------------------------------

  def test_retrying_job_goes_back_on_its_queue_with_its_attempt_refunded
    jid = seed(Wurk::RetrySet.new, { 'retry_count' => 3 })

    status, _headers, body = post("/v1/retries/#{jid}/retry")

    assert_equal 200, status
    assert_equal({ 'jid' => jid, 'set' => 'retry', 'queue' => @queue }, body)
    assert_nil Wurk::RetrySet.new.find_job(jid)
    queued = Wurk::Queue.new(@queue).find_job(jid)

    assert_equal 2, queued['retry_count']
  end

  def test_retry_by_score_reads_one_score_instead_of_scanning
    at = Time.now.to_f + 600
    jid = seed(Wurk::RetrySet.new, at: at)
    entry = Wurk::API::Jobs.find_entry(UnscannableSet.new('retry'), jid, at)

    assert_equal jid, entry.jid
    status, = post("/v1/retries/#{jid}/retry?score=#{at}")

    assert_equal 200, status
    refute_nil Wurk::Queue.new(@queue).find_job(jid)
  end

  def test_retry_with_the_wrong_score_finds_nothing
    jid = seed(Wurk::RetrySet.new)

    status, _headers, body = post("/v1/retries/#{jid}/retry?score=1")

    assert_equal 404, status
    assert_equal 'job_not_found', body['type']
    refute_nil Wurk::RetrySet.new.find_job(jid)
  end

  def test_retry_refuses_a_score_that_is_not_a_number
    jid = seed(Wurk::RetrySet.new)

    %w[soon 1&score=2 nan inf -Infinity].each do |score|
      status, _headers, body = post("/v1/retries/#{jid}/retry?score=#{score}")

      assert_equal 400, status
      assert_match(/score/, body['detail'])
    end
  end

  def test_retry_of_an_unknown_jid_is_job_not_found
    status, _headers, body = post("/v1/retries/#{SecureRandom.hex(12)}/retry")

    assert_equal 404, status
    assert_equal 'job_not_found', body['type']
    assert_match(/retry/, body['detail'])
  end

  def test_retry_needs_the_admin_scope
    jid = seed(Wurk::RetrySet.new)

    status, _headers, body = post("/v1/retries/#{jid}/retry", token: READ_TOKEN)

    assert_equal 403, status
    assert_equal 'admin', body['required_scope']
    refute_nil Wurk::RetrySet.new.find_job(jid)
  end

  # The second send of a retry whose reply was lost replays the first answer
  # instead of reporting the job it just moved as missing.
  def test_a_resent_retry_under_its_idempotency_key_replays_the_first_answer
    jid = seed(Wurk::RetrySet.new)
    path = "/v1/retries/#{jid}/retry"

    first = post(path, headers: { 'HTTP_IDEMPOTENCY_KEY' => "k-#{@ns}" })
    status, headers, body = post(path, headers: { 'HTTP_IDEMPOTENCY_KEY' => "k-#{@ns}" })

    assert_equal 200, first[0]
    assert_equal 200, status
    assert_equal 'true', headers['idempotency-replayed']
    assert_equal first[2], body
    assert_equal 1, Wurk::Queue.new(@queue).size
  end

  # --- POST /dead/:jid/retry -------------------------------------------------

  def test_dead_job_goes_back_on_its_queue
    jid = seed(Wurk::DeadSet.new, { 'retry_count' => 25 })

    status, _headers, body = post("/v1/dead/#{jid}/retry")

    assert_equal 200, status
    assert_equal 'dead', body['set']
    assert_nil Wurk::DeadSet.new.find_job(jid)
    assert_equal 24, Wurk::Queue.new(@queue).find_job(jid)['retry_count']
  end

  def test_dead_retry_does_not_reach_into_the_retry_set
    jid = seed(Wurk::RetrySet.new)

    status, = post("/v1/dead/#{jid}/retry")

    assert_equal 404, status
    refute_nil Wurk::RetrySet.new.find_job(jid)
  end

  # --- POST /queues/:name/clear ----------------------------------------------

  def test_clear_empties_the_queue_and_drops_it_from_the_queues_set
    2.times { Wurk::Client.new.push(job) }

    status, _headers, body = post("/v1/queues/#{@queue}/clear")

    assert_equal 200, status
    assert_equal({ 'name' => @queue, 'cleared' => true }, body)
    assert_equal 0, Wurk::Queue.new(@queue).size
    refute_includes Wurk::Queue.all.map(&:name), @queue
  end

  # A replayed clear must not empty what a producer enqueued after the first.
  def test_a_resent_clear_under_its_idempotency_key_clears_nothing_new
    key = { 'HTTP_IDEMPOTENCY_KEY' => "c-#{@ns}" }
    post("/v1/queues/#{@queue}/clear", headers: key)
    jid = Wurk::Client.new.push(job)

    status, headers, = post("/v1/queues/#{@queue}/clear", headers: key)

    assert_equal 200, status
    assert_equal 'true', headers['idempotency-replayed']
    refute_nil Wurk::Queue.new(@queue).find_job(jid)
  end

  def test_clear_refuses_an_invalid_queue_name
    status, _headers, body = post('/v1/queues/a%20b/clear')

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  def test_clear_refuses_an_oversized_body_before_touching_the_queue
    Wurk::Client.new.push(job)
    config.api_max_body_bytes = 4

    status, _headers, body = post("/v1/queues/#{@queue}/clear", body: '{"x":1}')

    assert_equal 413, status
    assert_equal 'payload_too_large', body['type']
    assert_equal 1, Wurk::Queue.new(@queue).size
  end

  # --- DELETE /jobs/:jid?score= ----------------------------------------------

  def test_delete_by_score_removes_the_scheduled_job
    at = Time.now.to_f + 900
    jid = seed(Wurk::ScheduledSet.new, at: at)

    status, _headers, body = request('DELETE', "/v1/jobs/#{jid}?score=#{at}")

    assert_equal 200, status
    assert_equal 'schedule', body['set']
    assert_nil Wurk::ScheduledSet.new.find_job(jid)
  end

  # --- GET /batches ------------------------------------------------------------

  def test_batches_lists_newest_first_with_counts_not_jids
    older = seed_batch(Time.now.to_f - 10)
    newer = seed_batch(Time.now.to_f)
    Wurk.redis { |conn| conn.call('SADD', "b-#{newer}-failed", 'j1', 'j2') }

    status, _headers, body = get('/v1/batches?count=1')

    assert_equal 200, status
    assert_equal 2, body['total']
    assert_equal 1, body['count']
    assert_equal([newer], body['batches'].map { |row| row['bid'] })
    assert_equal 2, body['batches'].first['failed_count']
    refute body['batches'].first.key?('failed_jids')

    _status, _headers, page_two = get('/v1/batches?count=1&page=1')

    assert_equal([older], page_two['batches'].map { |row| row['bid'] })
  end

  private

  def app = @app ||= Wurk::API::App.new(config: config)

  def config
    @config ||= Wurk::Configuration.new.tap do |cfg|
      cfg.api_token(ADMIN_TOKEN, scopes: %i[admin])
      cfg.api_token(READ_TOKEN, scopes: %i[read])
    end
  end

  def job(**fields)
    { 'class' => "ApiAdminWorker#{@ns}", 'args' => [], 'queue' => @queue }.merge(fields.transform_keys(&:to_s))
  end

  def seed(set, fields = {}, at: Time.now.to_f + 60)
    jid = SecureRandom.hex(12)
    set.schedule(at, job.merge('jid' => jid).merge(fields))
    jid
  end

  def seed_batch(created_at)
    bid = SecureRandom.urlsafe_base64(10)
    Wurk.redis do |conn|
      conn.call('HSET', "b-#{bid}", 'created_at', created_at.to_s, 'tags', '[]')
      conn.call('ZADD', 'batches', created_at, bid)
    end
    bid
  end

  def get(path, token: ADMIN_TOKEN) = request('GET', path, token: token)

  def post(path, token: ADMIN_TOKEN, headers: {}, body: '')
    request('POST', path, token: token, headers: headers, body: body)
  end

  def request(method, path, token: ADMIN_TOKEN, headers: {}, body: '')
    info, _, query = path.partition('?')
    env = {
      'REQUEST_METHOD' => method, 'PATH_INFO' => info, 'SCRIPT_NAME' => '', 'QUERY_STRING' => query,
      'rack.input' => StringIO.new(body), 'rack.errors' => StringIO.new,
      'HTTP_AUTHORIZATION' => "Bearer #{token}"
    }.merge(headers)
    status, response_headers, response_body = app.call(env)
    [status, response_headers, JSON.parse(response_body.join)]
  end
end
