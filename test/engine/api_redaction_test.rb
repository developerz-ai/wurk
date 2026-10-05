# frozen_string_literal: true

require_relative '../engine_test_helper'

# `config[:redact_args]` in the dashboard JSON: the queue and retry listings
# show the hook's array, while the payload in Redis stays byte-for-byte what
# was pushed.
class ApiRedactionTest < Wurk::Test::EngineCase
  parallelize_me!

  REDACTOR = ->(job) { [job['args'].first, '[FILTERED]'] }

  def setup
    super
    @ns = "wurkredact:#{::Process.pid}:#{object_id}"
    @queue = "#{@ns}-q"
    # The dummy app's options may already be frozen by an earlier boot path;
    # the hook is read per request, so a swapped-in copy is enough.
    @original = ::Wurk.configuration.instance_variable_get(:@options)
    @options = @original.merge(redact_args: REDACTOR)
    ::Wurk.configuration.instance_variable_set(:@options, @options)
    @retry_members = []
  end

  def teardown
    ::Wurk.configuration.instance_variable_set(:@options, @original)
    ::Wurk.redis do |c|
      c.call('DEL', "queue:#{@queue}")
      c.call('SREM', 'queues', @queue)
      # `retry` is shared with every other test on this DB; only our own member goes.
      c.call('ZREM', 'retry', *@retry_members) unless @retry_members.empty?
    end
  ensure
    super
  end

  def test_queue_listing_shows_redacted_args_and_redis_is_untouched
    raw = push('queue')
    get "/wurk/api/queues/#{@queue}"

    assert_equal 200, last_response.status
    job = JSON.parse(last_response.body)['jobs'].find { |j| j['jid'] == 'redact-jid' }

    assert_equal ['user-1', '[FILTERED]'], job['args']
    refute_includes last_response.body, 's3cret'
    assert_equal([raw], ::Wurk.redis { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) })
  end

  def test_retry_listing_shows_redacted_args
    push('retry')
    get '/wurk/api/retries'

    assert_equal 200, last_response.status
    entry = JSON.parse(last_response.body)['entries'].find { |e| e['jid'] == 'redact-jid' }

    assert_equal ['user-1', '[FILTERED]'], entry['args']
  end

  def test_raising_hook_fails_closed
    @options[:redact_args] = ->(_job) { raise 'boom' }
    push('queue')
    get "/wurk/api/queues/#{@queue}"

    job = JSON.parse(last_response.body)['jobs'].find { |j| j['jid'] == 'redact-jid' }

    assert_equal Wurk::Redact::FAILED, job['args']
    refute_includes last_response.body, 's3cret'
  end

  private

  def push(where)
    raw = ::Wurk.dump_json('class' => 'RedactJob', 'queue' => @queue, 'jid' => 'redact-jid',
                           'args' => ['user-1', { 'password' => 's3cret' }],
                           'created_at' => Time.now.to_f, 'enqueued_at' => Time.now.to_f)
    ::Wurk.redis do |c|
      if where == 'queue'
        c.call('SADD', 'queues', @queue)
        c.call('LPUSH', "queue:#{@queue}", raw)
      else
        c.call('ZADD', 'retry', Time.now.to_f.to_s, raw)
        @retry_members << raw
      end
    end
    raw
  end
end
