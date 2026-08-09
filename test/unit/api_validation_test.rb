# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'json'
require 'stringio'

# Slice 07 — what the produce plane refuses before Wurk::Client sees it.
#
# JobUtil validates a job hash written by Ruby running in this process; these
# routes take one typed by a stranger, and `job_util.rb`'s TRANSIENT_ATTRIBUTES
# is a strip-list with no allow-list behind it. Everything below is the
# allow-list the API has to supply instead, asserted through the real Rack app
# against real Redis — a rejection that still enqueued would be the only kind
# worth catching.
#
# Parallel safety: queue and class names carry a per-instance namespace, and
# the worker's Redis DB is flushed after every test (RedisNamespace).
class ApiValidationTest < Wurk::Test::UnitCase
  parallelize_me!

  LIB = File.expand_path('../../lib', __dir__)

  ADMIN_TOKEN = 'api-validation-admin-0123456789'
  ENQUEUE_TOKEN = 'api-validation-enqueue-0123456789'

  def setup
    super
    @ns = "#{Process.pid}_#{object_id}"
    @queue = "q-#{@ns}"
    @class_name = "ApiValidationWorker#{@ns}"
    @pool = Wurk.configuration.redis_pool
  end

  # --- Class name is a code selector, not data ---------------------------

  def test_a_namespaced_class_name_is_accepted
    @class_name = "Billing#{@ns}::Charge"
    status, = post('/v1/jobs', job)

    assert_equal 201, status
    assert_equal @class_name, queued_payloads.fetch(0)['class']
  end

  def test_anything_that_is_not_a_constant_path_is_refused
    ['hardWorker', 'Hard Worker', 'Hard;Worker', '../../etc/passwd', 'Hard::worker', '', '9Lives',
     'Kernel#system', "Hard\nWorker"].each do |name|
      status, _headers, body = post('/v1/jobs', job.merge('class' => name))

      assert_equal 400, status, "#{name.inspect} was accepted"
      assert_equal 'invalid_request', body['type']
    end
    assert_empty queued_payloads
  end

  def test_a_class_that_is_not_a_string_is_refused
    [123, ['HardWorker'], { 'name' => 'HardWorker' }, nil, true].each do |value|
      status, = post('/v1/jobs', job.merge('class' => value))

      assert_equal 400, status, "#{value.inspect} was accepted"
    end
  end

  # Bounded before it is matched, stored in a payload, or echoed back in the
  # error that refuses it.
  def test_an_unbounded_class_name_is_refused
    status, _headers, body = post('/v1/jobs', job.merge('class' => "A#{'a' * 300}"))

    assert_equal 400, status
    refute_includes JSON.generate(body), 'aaaaaaaaaa'
  end

  # A body with no `class` at all is Client's error to name: it says which
  # required keys are missing, which is more useful than "that is not a class".
  def test_a_missing_class_is_left_to_the_client_to_name
    status, _headers, body = post('/v1/jobs', { 'args' => [] })

    assert_equal 400, status
    assert_includes body['detail'], "'class' and 'args'"
  end

  # --- Unknown top-level keys --------------------------------------------

  def test_an_unknown_top_level_key_is_refused_and_named
    status, _headers, body = post('/v1/jobs', job.merge('deadlin' => 30))

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
    assert_equal ['deadlin'], body['unknown_keys']
    assert_empty queued_payloads
  end

  # Every one of these is written by the server or names a Ruby object, and
  # accepting any of them lets a producer lie: about its own queue latency,
  # about how often it has been retried, or about belonging to a batch whose
  # `pending` counter was never incremented for it.
  def test_server_owned_fields_are_not_settable_from_the_network
    %w[created_at enqueued_at retry_count failed_at retried_at error_class expiry deadline_at bid
       pool client_class].each do |key|
      status, _headers, body = post('/v1/jobs', job.merge(key => 'x'))

      assert_equal 400, status, "#{key} was accepted"
      assert_equal [key], body['unknown_keys']
    end
    assert_empty queued_payloads
  end

  def test_every_documented_job_option_is_accepted
    payload = Wurk::API::Validation::JOB_KEYS.to_h { |key| [key, nil] }

    assert_nil Wurk::API::Validation.known_keys!(payload, Wurk::API::Validation::JOB_KEYS)
  end

  def test_the_bulk_envelope_keys_are_accepted_only_on_the_bulk_route
    status, = post('/v1/jobs/bulk', job(args: [[1]], batch_size: 10, spread_interval: 60))

    assert_equal 201, status

    status, _headers, body = post('/v1/jobs', job.merge('batch_size' => 10))

    assert_equal 400, status
    assert_equal ['batch_size'], body['unknown_keys']
  end

  # The keys came off the network, so the echo that lets a client find its typo
  # is bounded the same way the JSON parser's own message is never forwarded.
  def test_the_report_of_unknown_keys_is_bounded
    noise = (1..20).to_h { |i| ["zz#{i}#{'y' * 100}", 1] }
    _status, _headers, body = post('/v1/jobs', job.merge(noise))

    assert_equal Wurk::API::Validation::MAX_REPORTED_KEYS, body['unknown_keys'].size
    body['unknown_keys'].each do |key|
      assert_operator key.length, :<=, Wurk::API::Validation::MAX_REPORTED_KEY_LENGTH
    end
  end

  # --- A jid in the body --------------------------------------------------

  def test_a_body_jid_is_held_to_the_same_shape_as_a_path_one
    status, = post('/v1/jobs', job(jid: 'abc-123_DEF'))

    assert_equal 201, status

    status, _headers, body = post('/v1/jobs', job(jid: 'has spaces'))

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  # `push_bulk` takes a `jid` too, for a one-job bulk.
  def test_the_bulk_route_holds_a_body_jid_to_the_same_shape
    status, = post('/v1/jobs/bulk', job(args: [[1]], jid: 'abc-123_DEF'))

    assert_equal 201, status

    status, _headers, body = post('/v1/jobs/bulk', job(args: [[1]], jid: '*'))

    assert_equal 400, status
    assert_equal 'invalid_request', body['type']
  end

  def test_a_bulk_with_no_class_is_left_to_the_client_to_name
    status, _headers, body = post('/v1/jobs/bulk', { 'args' => [[1]] })

    assert_equal 400, status
    assert_includes body['detail'], "'class' and 'args'"
    assert_empty queued_payloads
  end

  # --- Size caps ----------------------------------------------------------

  def test_args_larger_than_the_cap_are_refused_before_the_push
    status, headers, body = post('/v1/jobs', job(args: ['x' * 200]), config: capped(args: 100))

    assert_equal 413, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'payload_too_large', body['type']
    assert_equal 'Payload Too Large', body['title']
    assert_equal 100, body['max_bytes']
    assert_empty queued_payloads
  end

  def test_args_at_the_cap_are_accepted
    args = ['x' * 50]
    status, = post('/v1/jobs', job(args: args), config: capped(args: JSON.generate(args).bytesize))

    assert_equal 201, status
  end

  # For a bulk push the body cap bounds the request and this bounds each job it
  # becomes — only the second bounds what lands in Redis.
  def test_a_single_oversized_job_refuses_the_whole_bulk
    payload = job(args: [[1], ['x' * 200], [3]])
    status, _headers, body = post('/v1/jobs/bulk', payload, config: capped(args: 100))

    assert_equal 413, status
    assert_equal 'payload_too_large', body['type']
    assert_equal 1, body['job_index']
    assert_empty queued_payloads
  end

  # `args` that is not an array at all is Client's rejection to name, with the
  # offending value in the message — there is nothing here to size.
  def test_an_unsizeable_args_is_left_to_the_client
    status, _headers, body = post('/v1/jobs/bulk', job(args: 'nope'), config: capped(args: 10))

    assert_equal 400, status
    assert_includes body['detail'], 'Array of Arrays'
  end

  def test_a_body_larger_than_the_cap_is_refused
    status, _headers, body = post('/v1/jobs', job(args: ['x' * 500]), config: capped(body: 100))

    assert_equal 413, status
    assert_equal 'payload_too_large', body['type']
    assert_equal 100, body['max_bytes']
    assert_empty queued_payloads
  end

  # Refused on the strength of a cap-sized read, never by buffering the body to
  # measure it — the whole point of a body cap is that an oversized request
  # costs the process nothing.
  def test_an_oversized_body_is_never_read_past_the_cap
    input = CountingInput.new(JSON.generate(job(args: ['x' * 100_000])))
    env = env_for('POST', '/v1/jobs')
    env['rack.input'] = input
    status, = parse(app(capped(body: 100)).call(env))

    assert_equal 413, status
    assert_equal [101], input.reads
  end

  # --- The class allow-list ----------------------------------------------

  # `class` selects which of the host's jobs runs, so a producer credential
  # that can name any constant is choosing.
  def test_without_a_list_an_enqueue_token_may_enqueue_nothing
    status, headers, body = post('/v1/jobs', job, token: ENQUEUE_TOKEN, config: unlisted)

    assert_equal 403, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'class_not_allowed', body['type']
    assert_equal 'Class Not Allowed', body['title']
    assert_equal @class_name, body['job_class']
    assert_empty queued_payloads
  end

  # An admin token already holds the destructive routes, so restricting which
  # class it may enqueue while no list exists would be theatre.
  def test_without_a_list_an_admin_token_may_enqueue_anything
    status, = post('/v1/jobs', job, config: unlisted)

    assert_equal 201, status
  end

  def test_a_list_admits_exactly_what_it_names
    status, = post('/v1/jobs', job, token: ENQUEUE_TOKEN)

    assert_equal 201, status

    status, _headers, body = post('/v1/jobs', job.merge('class' => 'SomethingElse'), token: ENQUEUE_TOKEN)

    assert_equal 403, status
    assert_equal 'SomethingElse', body['job_class']
  end

  # A host that writes a list means it.
  def test_a_list_binds_an_admin_token_too
    status, = post('/v1/jobs', job.merge('class' => 'SomethingElse'))

    assert_equal 403, status
  end

  def test_the_bulk_route_is_held_to_the_same_list
    status, = post('/v1/jobs/bulk', job(args: [[1]]).merge('class' => 'SomethingElse'), token: ENQUEUE_TOKEN)

    assert_equal 403, status
    assert_empty queued_payloads
  end

  # The escape hatch an enqueue-scoped relay needs, so the alternative isn't
  # handing it `admin` and the destructive routes that come with it.
  def test_any_turns_the_check_off_without_admitting_a_bad_name
    status, = post('/v1/jobs', job.merge('class' => 'Whatever::Else'), token: ENQUEUE_TOKEN, config: unrestricted)

    assert_equal 201, status

    status, = post('/v1/jobs', job.merge('class' => 'not a class'), token: ENQUEUE_TOKEN, config: unrestricted)

    assert_equal 400, status
  end

  # --- Declaring the boundary --------------------------------------------

  def test_the_allow_list_is_validated_where_it_is_declared
    fresh = Wurk::Configuration.new

    assert_raises(ArgumentError) { fresh.api_enqueue_classes = ['not a class'] }
    assert_raises(ArgumentError) { fresh.api_enqueue_classes = [] }
    assert_raises(ArgumentError) { fresh.api_enqueue_classes = :anything }
  end

  def test_the_allow_list_accepts_names_classes_any_and_nil
    fresh = Wurk::Configuration.new
    fresh.api_enqueue_classes = ['Billing::Charge', Wurk::Configuration]

    assert_equal ['Billing::Charge', 'Wurk::Configuration'], fresh.api_enqueue_classes
    assert_predicate fresh.api_enqueue_classes, :frozen?

    fresh.api_enqueue_classes = :any

    assert_equal :any, fresh.api_enqueue_classes

    fresh.api_enqueue_classes = nil

    assert_nil fresh.api_enqueue_classes
  end

  # A cap that silently coerced to 0 is a cap that isn't one, and the request
  # path is the wrong place to discover that.
  def test_a_cap_must_be_a_positive_integer
    fresh = Wurk::Configuration.new

    %i[api_max_body_bytes= api_max_args_bytes= api_idempotency_ttl=].each do |writer|
      [0, -1, nil, 'lots', ''].each do |value|
        assert_raises(ArgumentError, "#{writer} accepted #{value.inspect}") { fresh.public_send(writer, value) }
      end
    end
  end

  def test_the_defaults_are_positive_and_the_writers_take
    fresh = Wurk::Configuration.new

    assert_operator fresh.api_max_body_bytes, :>, 0
    assert_operator fresh.api_max_args_bytes, :>, 0
    assert_operator fresh.api_idempotency_ttl, :>, 0

    fresh.api_max_body_bytes = 2048

    assert_equal 2048, fresh.api_max_body_bytes
  end

  def test_a_frozen_configuration_refuses_new_boundaries
    frozen = Wurk::Configuration.new.tap(&:freeze!)

    assert_raises(FrozenError) { frozen.api_max_body_bytes = 10 }
    assert_raises(FrozenError) { frozen.api_enqueue_classes = ['HardWorker'] }
  end

  # The additive invariant, config-side: the caps are seeded in DEFAULTS so a
  # frozen config still answers for them, but the module that reads them is
  # only loaded by a host that declares an allow-list. A swarm child that
  # serves no HTTP API carries none of it in its pre-fork heap. Subprocess,
  # because this process has already required it.
  def test_the_boundary_module_loads_only_when_a_boundary_is_declared
    probe = 'print $LOADED_FEATURES.grep(%r{wurk/api/(validation|idempotency)\.rb\z}).size'

    assert_equal '0', ruby("require 'wurk'; #{probe}")
    assert_equal '1', ruby("require 'wurk'; Wurk.configuration.api_enqueue_classes = %w[HardWorker]; #{probe}")
  end

  private

  # Records the length of every read the app asked for.
  class CountingInput
    attr_reader :reads

    def initialize(string)
      @io = StringIO.new(string)
      @reads = []
    end

    def read(length = nil, buffer = nil)
      @reads << length
      @io.read(length, buffer)
    end
  end

  def app(cfg = config) = Wurk::API::App.new(config: cfg)

  def config
    @config ||= build_config { |cfg| cfg.api_enqueue_classes = [@class_name] }
  end

  def unlisted = build_config
  def unrestricted = build_config { |cfg| cfg.api_enqueue_classes = :any }

  def capped(body: nil, args: nil)
    build_config do |cfg|
      cfg.api_enqueue_classes = [@class_name]
      cfg.api_max_body_bytes = body if body
      cfg.api_max_args_bytes = args if args
    end
  end

  def build_config
    Wurk::Configuration.new.tap do |cfg|
      cfg.api_token(ADMIN_TOKEN, scopes: %i[admin])
      cfg.api_token(ENQUEUE_TOKEN, scopes: %i[enqueue])
      yield cfg if block_given?
    end
  end

  def job(**overrides)
    { 'class' => @class_name, 'args' => [], 'queue' => @queue }.merge(overrides.transform_keys(&:to_s))
  end

  def queued_payloads
    @pool.with { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |raw| JSON.parse(raw) }
  end

  def post(path, payload, token: ADMIN_TOKEN, config: nil)
    raw = JSON.generate(payload)
    parse(app(config || self.config).call(env_for('POST', path, body: raw, token: token)))
  end

  def parse(response)
    status, headers, body = response
    [status, headers, JSON.parse(body.join)]
  end

  def ruby(script)
    IO.popen([RbConfig.ruby, '-I', LIB, '-e', script], err: %i[child out], &:read)
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
