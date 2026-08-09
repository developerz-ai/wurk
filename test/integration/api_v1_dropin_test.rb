# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'json'
require 'securerandom'
require 'stringio'

# Slice 07, task 45 — "the headline drop-in test" (07-http-producer-api.md):
# an HTTP-enqueued job must be indistinguishable from a Ruby-enqueued one.
# Three proofs, none of them mocking Redis:
#
#   1. byte-compare — the exact bytes POST /jobs writes to the queue list
#      against what Wurk::Client#push writes for the same input.
#   2. stock-Sidekiq oracle — the pinned, verbatim-fetched fragment of
#      Sidekiq::Processor#dispatch / JobLogger#prepare (same SHA
#      test/parity/.sidekiq_sha pins, e1f808a08645f9b8a194852a171b5667f5f877bd,
#      previously fetched for TelemetryClientMiddlewareTest) resolves and
#      dispatches an HTTP-enqueued payload unmodified.
#   3. real fork — a real Wurk::Swarm, forked from this process, pops and
#      runs a job this test enqueued over HTTP.
class ApiV1DropinTest < Wurk::Test::UnitCase
  parallelize_me!

  ENQUEUE_TOKEN = 'api-dropin-enqueue-token-0123456789'

  def setup
    super
    @ns = "apidropin-#{::Process.pid}-#{object_id}"
    @queue = "#{@ns}-q"
    # No '@' or '-': Validation::CLASS_FORMAT (a Ruby constant path) refuses
    # both, and this class name has to clear the HTTP boundary's allow-list.
    @class_name = "ApiDropinJob#{::Process.pid}#{object_id}".delete('-')
  end

  def teardown
    Wurk.redis do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
    end
  ensure
    super
  end

  # --- 1. byte-compare -------------------------------------------------

  # Same explicit jid on both pushes and the identical `fields` key order
  # feeding both the JSON body and the direct Ruby call, so the only bytes
  # that can legitimately differ are the two clock-stamped fields
  # (`created_at`, `enqueued_at`) — everything else, key order and encoding
  # included, has to match exactly or this fails.
  def test_an_http_enqueued_payload_is_byte_identical_to_a_ruby_push
    jid = SecureRandom.hex(12)
    fields = {
      'class' => @class_name, 'args' => [1, 'two', { 'nested' => [3, 4] }],
      'queue' => @queue, 'jid' => jid, 'retry' => 3, 'tags' => %w[a b]
    }

    status, _headers, body = post_http('/v1/jobs', fields)

    assert_equal 201, status
    assert_equal jid, body['jid']
    http_raw = pop_raw

    Wurk::Client.new.push(fields.dup)
    direct_raw = pop_raw

    refute_nil http_raw, 'the HTTP push wrote nothing to the queue'
    refute_nil direct_raw, 'the direct Client#push wrote nothing to the queue'
    assert_equal scrub_timestamps(direct_raw), scrub_timestamps(http_raw),
                 'an HTTP-enqueued payload must be byte-identical to Wurk::Client#push for the same input'
  end

  # --- 2. stock-Sidekiq oracle -------------------------------------------
  #
  # `Sidekiq::Processor#dispatch` and `Sidekiq::JobLogger#prepare`, pinned at
  # test/parity/.sidekiq_sha (e1f808a08645f9b8a194852a171b5667f5f877bd):
  #
  #   # lib/sidekiq/processor.rb:137,148-150
  #   @job_logger.prepare(job_hash) do
  #     ...
  #     klass = Object.const_get(job_hash["class"])
  #     instance = klass.new
  #     instance.jid = job_hash["jid"]
  #
  #   # lib/sidekiq/job_logger.rb:26-33
  #   def prepare(job_hash, &block)
  #     h = { jid: job_hash["jid"], class: job_hash["wrapped"] || job_hash["class"] }
  #     @config[:logged_job_attributes].each do |attr|
  #       h[attr.to_sym] = job_hash[attr] if job_hash.has_key?(attr)
  #     end
  #
  # `Sidekiq.load_json` is a bare `JSON.parse` (lib/sidekiq.rb:62) and every
  # access above is `Hash#[]`/`#has_key?` by known key name — nothing
  # enumerates or validates the full key set. Running this exact fragment
  # against a real HTTP-enqueued payload is what actually proves stock
  # Sidekiq's own Processor can pick the job up, not just that the payload's
  # shape looks right in isolation.
  def stock_sidekiq_dispatch(jobstr)
    job_hash = JSON.parse(jobstr)
    prepared = { jid: job_hash['jid'], class: job_hash['wrapped'] || job_hash['class'] }
    klass = Object.const_get(job_hash['class'])
    instance = klass.new
    instance.jid = job_hash['jid']
    { instance: instance, args: job_hash['args'], prepared: prepared }
  end

  def test_an_http_enqueued_job_dispatches_unmodified_through_stock_sidekiqs_processor
    status, _headers, body = post_http(
      '/v1/jobs', 'class' => ApiDropinDispatchWorker.name, 'args' => [1, 'two'], 'queue' => @queue
    )

    assert_equal 201, status

    dispatched = stock_sidekiq_dispatch(pop_raw)

    assert_instance_of ApiDropinDispatchWorker, dispatched[:instance]
    assert_equal body['jid'], dispatched[:instance].jid
    assert_equal [1, 'two'], dispatched[:args]
    assert_equal({ jid: body['jid'], class: ApiDropinDispatchWorker.name }, dispatched[:prepared])
  end

  # --- 3. a real Wurk swarm runs it ---------------------------------------
  #
  # #07 done-when: "A non-Ruby process can enqueue, and a Wurk swarm runs the
  # job." Real fork, real Redis — this is the one test that proves it end to
  # end rather than at the payload-shape or router level.
  def test_a_wurk_swarm_runs_a_job_enqueued_over_http
    sentinel_key = "#{@ns}-sentinel"
    status, _headers, body = post_http(
      '/v1/jobs',
      'class' => ApiDropinForkWorker.name, 'args' => [Wurk::Test.redis_url, sentinel_key], 'queue' => @queue
    )

    assert_equal 201, status
    jid = body['jid']

    swarm = Wurk::Swarm.new(topology: topology_n(1), config: swarm_config, shutdown_timeout: 5)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      pid = wait_for_sentinel(sentinel_key)

      refute_nil pid, "job #{jid}, enqueued over HTTP, never ran within the wait window"
      refute_equal ::Process.pid.to_s, pid, 'the job must run in a forked child, not the test process'
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
      Wurk.redis { |c| c.call('DEL', sentinel_key) }
    end
  end

  private

  def api_app
    @api_app ||= Wurk::API::App.new(config: api_config)
  end

  def api_config
    @api_config ||= Wurk::Configuration.new.tap do |cfg|
      cfg.logger = ::Logger.new(IO::NULL)
      cfg.api_token(ENQUEUE_TOKEN, scopes: %i[enqueue])
      cfg.api_enqueue_classes = [@class_name, ApiDropinDispatchWorker.name, ApiDropinForkWorker.name]
    end
  end

  def post_http(path, payload)
    raw = JSON.generate(payload)
    env = {
      'REQUEST_METHOD' => 'POST', 'PATH_INFO' => path, 'SCRIPT_NAME' => '', 'QUERY_STRING' => '',
      'CONTENT_TYPE' => 'application/json', 'CONTENT_LENGTH' => raw.bytesize.to_s,
      'HTTP_AUTHORIZATION' => "Bearer #{ENQUEUE_TOKEN}",
      'rack.input' => StringIO.new(raw), 'rack.errors' => StringIO.new
    }
    status, headers, body = api_app.call(env)
    [status, headers, JSON.parse(body.join)]
  end

  # FIFO: LPUSH writes to the head, so the tail is the oldest (here, the only)
  # entry — read right after each push so the two pushes in the byte-compare
  # test can never be misattributed to each other.
  def pop_raw
    Wurk.redis { |c| c.call('RPOP', "queue:#{@queue}") }
  end

  def scrub_timestamps(raw)
    raw.gsub(/"(created_at|enqueued_at)":[0-9.]+/, '"\1":<stamp>')
  end

  def topology_n(count) = Wurk::Topology.flat(count: count, queues: [@queue], concurrency: 1)

  def swarm_config
    @swarm_config ||= Wurk::Configuration.new.tap do |cfg|
      cfg.logger = ::Logger.new(IO::NULL)
      cfg[:timeout] = 5
    end
  end

  def wait_for_sentinel(key, timeout: 20.0, interval: 0.1)
    deadline = monotonic_now + timeout
    while monotonic_now < deadline
      value = Wurk.redis { |c| c.call('GET', key) }
      return value if value

      sleep interval
    end
    nil
  end

  def monotonic_now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
end

# A real, resolvable constant — `Object.const_get` needs an actual class on
# the lookup path, not a per-test synthetic string name, and stock Sidekiq's
# dispatch really does call `.new` and `.jid=` on it.
class ApiDropinDispatchWorker
  attr_accessor :jid
end

# Top-level so Object.const_get(name) resolves inside the forked swarm child,
# which inherits the constant table but has no Minitest test-class lexical
# scope (same reasoning as TelemetryForkWorker / StatusCrossProcessWorker).
class ApiDropinForkWorker
  include Wurk::Job

  def perform(redis_url, sentinel_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', sentinel_key, ::Process.pid.to_s, 'EX', 60)
  ensure
    client&.close
  end
end
