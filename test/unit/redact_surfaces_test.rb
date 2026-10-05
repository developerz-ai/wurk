# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'wurk/web/search'
require 'json'
require 'securerandom'
require 'stringio'

# `redact_args` is applied once, in JobRecord#display_args, so every surface
# that renders a job shows the hook's array: search, the /v1 machine API and
# the data API itself — while Redis keeps the bytes that were pushed.
class RedactSurfacesTest < Wurk::Test::UnitCase
  parallelize_me!

  TOKEN = 'redact-surfaces-admin-token-0123456789'
  REDACTOR = ->(job) { [job['args'].first, '[FILTERED]'] }

  def setup
    super
    @queue = "redact-#{Process.pid}-#{object_id}"
    # Swapped in as a copy: the global options may already be frozen, and the
    # hook is read per record.
    @original = Wurk.configuration.instance_variable_get(:@options)
    Wurk.configuration.instance_variable_set(:@options, @original.merge(redact_args: REDACTOR))
  end

  def teardown
    Wurk.configuration.instance_variable_set(:@options, @original)
  ensure
    super
  end

  def test_job_record_display_args_and_redis_untouched
    raw = push_raw

    record = Wurk::Queue.new(@queue).first

    assert_equal ['user-1', '[FILTERED]'], record.display_args
    assert_equal ['user-1', { 'password' => 's3cret' }], record.args, 'the real args are untouched'
    assert_equal([raw], Wurk.redis { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) })
  end

  def test_no_hook_keeps_encryption_masking
    Wurk.configuration.instance_variable_set(:@options, @original)
    Wurk.redis do |c|
      c.call('LPUSH', "queue:#{@queue}", Wurk.dump_json(job('args' => ['plain', { 'wurk_encrypted' => 'x' }],
                                                            'encrypt' => true)))
    end

    assert_equal ['plain', '[encrypted data]'], Wurk::Queue.new(@queue).first.display_args
  end

  def test_search_hits_are_redacted
    push_raw
    Wurk::RetrySet.new.schedule(Time.now.to_f + 60, job('jid' => SecureRandom.hex(12)))

    hits = Wurk::Web::Search.new('user-1').to_a

    assert_equal 2, hits.size
    hits.each { |hit| assert_equal ['user-1', '[FILTERED]'], hit[:args] }
  end

  def test_v1_queue_and_retry_rows_are_redacted
    push_raw
    Wurk::RetrySet.new.schedule(Time.now.to_f + 60, job('jid' => SecureRandom.hex(12)))

    queue_rows = get("/v1/queues/#{@queue}")['jobs']
    retry_rows = get('/v1/retries')['jobs']

    assert_equal([['user-1', '[FILTERED]']], queue_rows.map { |r| r['args'] })
    assert_equal([['user-1', '[FILTERED]']], retry_rows.map { |r| r['args'] })
  end

  def test_raising_hook_fails_closed
    Wurk.configuration.instance_variable_set(:@options, @original.merge(redact_args: ->(_) { raise 'boom' }))
    push_raw

    assert_equal Wurk::Redact::FAILED, Wurk::Queue.new(@queue).first.display_args
  end

  private

  def job(overrides = {})
    { 'class' => 'RedactJob', 'queue' => @queue, 'jid' => SecureRandom.hex(12),
      'args' => ['user-1', { 'password' => 's3cret' }],
      'created_at' => Time.now.to_f, 'enqueued_at' => Time.now.to_f }.merge(overrides)
  end

  def push_raw
    raw = Wurk.dump_json(job)
    Wurk.redis do |c|
      c.call('SADD', 'queues', @queue)
      c.call('LPUSH', "queue:#{@queue}", raw)
    end
    raw
  end

  def get(path)
    config = Wurk::Configuration.new.tap { |cfg| cfg.api_token(TOKEN, scopes: %i[admin]) }
    env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => path, 'SCRIPT_NAME' => '', 'QUERY_STRING' => '',
            'rack.input' => StringIO.new, 'rack.errors' => StringIO.new, 'HTTP_AUTHORIZATION' => "Bearer #{TOKEN}" }
    status, _headers, body = Wurk::API::App.new(config: config).call(env)

    assert_equal 200, status, body.join
    JSON.parse(body.join)
  end
end
