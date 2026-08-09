# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'json'
require 'stringio'

# Slice 07, task 49 — the per-token ceiling on the HTTP API.
#
# Built on `Wurk::Limiter::Window` rather than a second limiter, so the two
# claims worth pinning are that it behaves like one (a sliding window on the
# Redis clock, registered where every other limiter is listed) and that it costs
# nothing until a host asks for it.
#
# Parallel safety: tokens and queue names carry a per-instance namespace, and
# the worker's Redis DB is flushed after every test (RedisNamespace).
class ApiThrottleTest < Wurk::Test::UnitCase
  parallelize_me!

  TOKEN = 'api-throttle-token-0123456789abcd'
  OTHER_TOKEN = 'api-throttle-other-token-0123456'
  # Registration writes metadata once per limiter object, and the objects are
  # cached for the life of the process — so the test that reads that metadata
  # back needs a credential no earlier test has already built one for.
  REGISTRY_TOKEN = 'api-throttle-registry-token-01234'

  def setup
    super
    @pool = Wurk.configuration.redis_pool
  end

  # --- off unless asked for -----------------------------------------------

  def test_no_limit_configured_lets_everything_through
    10.times { assert_equal 200, get('/v1')[0] }
  end

  # The zero-cost claim, read off Redis rather than inferred from the status
  # codes: an unconfigured ceiling leaves no window and no registry entry.
  def test_no_limit_configured_touches_no_limiter_key
    5.times { get('/v1') }

    assert_empty limiter_keys
    assert_empty registered_limiters
  end

  def test_the_discovery_document_reports_no_ceiling
    assert_nil get('/v1')[2]['rate_limit']
  end

  # --- the ceiling --------------------------------------------------------

  def test_requests_up_to_the_limit_pass_and_the_next_is_refused
    limited!(3)

    3.times { |i| assert_equal 200, get('/v1')[0], "request #{i + 1}" }

    assert_equal 429, get('/v1')[0]
  end

  def test_the_refusal_says_how_long_to_wait
    limited!(1, interval: 60)
    get('/v1')
    status, headers, body = get('/v1')

    assert_equal 429, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'rate_limited', body['type']
    assert_equal 'Too Many Requests', body['title']
    assert_equal 1, body['limit']
    assert_equal 60, body['interval_seconds']
    assert_equal body['retry_after'], headers['retry-after'].to_i
    assert_operator body['retry_after'], :<=, 60
    assert_operator body['retry_after'], :>, 55
  end

  # Derived from when the window's oldest entry slides out, not from the
  # interval: a client that trickled up to the ceiling must not be told to wait
  # a full window for a slot that frees in a second.
  def test_the_wait_shrinks_as_the_window_ages
    limited!(1, interval: 4)
    get('/v1')
    sleep 2
    _status, _headers, body = get('/v1')

    assert_operator body['retry_after'], :>=, 1
    assert_operator body['retry_after'], :<, 4
  end

  # Never 0 — a client that reads "wait 0 seconds" retries immediately, which
  # is what got it throttled. A window whose oldest entry aged out between the
  # refusal and the read back is the case that produces one.
  def test_the_wait_is_never_zero
    lapsed = Struct.new(:status).new({ reset_at: ::Time.now.to_f - 30 })

    assert_equal 1, Wurk::API::Throttle.retry_after(lapsed, :minute)
  end

  # A window that emptied between the refusal and the read back has no oldest
  # entry to date the answer from, so the interval is the only honest wait left.
  def test_an_emptied_window_falls_back_to_the_interval
    empty = Struct.new(:status).new({ reset_at: nil })

    assert_equal 60, Wurk::API::Throttle.retry_after(empty, :minute)
    assert_equal 15, Wurk::API::Throttle.retry_after(empty, 15)
  end

  # `within_limit` sleeps until a slot frees, which is right for a worker
  # thread and wrong for a socket a client is holding open: the refusal is
  # already known, and holding the connection for a window helps nobody.
  def test_a_refusal_answers_immediately_rather_than_waiting_for_a_slot
    limited!(1, interval: 60)
    get('/v1')
    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    get('/v1')
    elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1.0
  end

  # Sliding, not a counter that has to be reset: the slot comes back on its own.
  def test_a_slot_frees_once_the_window_slides_past_it
    limited!(1, interval: 1)
    get('/v1')

    assert_equal 429, get('/v1')[0]

    sleep 1.1

    assert_equal 200, get('/v1')[0]
  end

  def test_the_discovery_document_advertises_the_ceiling
    limited!(30, interval: :minute)

    assert_equal({ 'limit' => 30, 'interval_seconds' => 60 }, get('/v1')[2]['rate_limit'])
  end

  # --- what gets charged --------------------------------------------------

  def test_the_ceiling_is_per_token
    limited!(1)
    get('/v1')

    assert_equal 429, get('/v1')[0]
    assert_equal 200, get('/v1', token: OTHER_TOKEN)[0]
  end

  # A client walking paths that do not exist is exactly the traffic a ceiling
  # is for, so a route miss costs a slot like anything else.
  def test_a_route_miss_is_charged
    limited!(1)

    assert_equal 404, get('/v1/nope')[0]
    assert_equal 429, get('/v1')[0]
  end

  # There is no credential to charge, and a stranger must not be able to spend
  # a real client's quota by guessing at its token.
  def test_an_unauthenticated_request_is_not_charged
    limited!(1)

    assert_equal 401, get('/v1', token: nil)[0]
    assert_equal 401, get('/v1', token: 'Bearer-shaped-but-wrong-0123456')[0]
    assert_equal 200, get('/v1')[0]
  end

  # Read-only is a fact this process already holds; the throttle is a Redis
  # round trip. The cheaper refusal runs first and the request never reaches
  # the window.
  def test_a_read_only_refusal_is_not_charged
    @config = build_config do |cfg|
      cfg.api_rate_limit = 1
      cfg.api_read_only = true
    end

    3.times { assert_equal 403, post('/v1/jobs')[0] }
    assert_empty limiter_keys
  end

  # --- it is a limiter like any other -------------------------------------

  # So `GET /v1/limiters` and the dashboard's Limiters page list an API ceiling
  # beside the ones the jobs use, instead of it being invisible state.
  def test_the_window_registers_itself_in_the_shared_registry
    limited!(2)
    get('/v1', token: REGISTRY_TOKEN)

    assert_equal [limiter_name(REGISTRY_TOKEN)], registered_limiters
  end

  # The name is a Redis key and shows up on a dashboard: it carries the
  # credential's fingerprint, never the credential.
  def test_the_window_is_named_for_the_fingerprint_not_the_token
    limited!(1)
    get('/v1')
    keys = limiter_keys

    assert_equal ["lmtr-w:#{limiter_name(TOKEN)}"], keys
    refute_includes keys.join, TOKEN
    assert_includes keys.join, Wurk::API::Auth.fingerprint(TOKEN)
  end

  # One limiter per credential and ceiling, kept: constructing one writes its
  # metadata, and paying that round trip per request would double the cost of
  # the whole feature.
  def test_a_limiter_is_built_once_per_credential_and_ceiling
    principal = Wurk::API::Auth::Principal.new(Wurk::API::Auth.fingerprint(TOKEN), %i[admin])
    first = Wurk::API::Throttle.for_principal(principal, 5, :minute)

    assert_same first, Wurk::API::Throttle.for_principal(principal, 5, :minute)
    refute_same first, Wurk::API::Throttle.for_principal(principal, 6, :minute)
    refute_same first, Wurk::API::Throttle.for_principal(principal, 5, :hour)
  end

  # --- the settings -------------------------------------------------------

  def test_a_ceiling_that_is_not_one_is_refused_where_it_is_written
    config = Wurk::Configuration.new

    [0, -5, 'lots', nil.to_s].each do |value|
      assert_raises(ArgumentError, value.inspect) { config.api_rate_limit = value }
    end
  end

  def test_nil_turns_the_ceiling_off
    config = Wurk::Configuration.new
    config.api_rate_limit = 10
    config.api_rate_limit = nil

    assert_nil config.api_rate_limit
  end

  def test_an_interval_the_limiter_cannot_read_is_refused_where_it_is_written
    config = Wurk::Configuration.new

    assert_raises(ArgumentError) { config.api_rate_limit_interval = :fortnight }
    assert_equal :minute, config.api_rate_limit_interval

    config.api_rate_limit_interval = 30

    assert_equal 30, config.api_rate_limit_interval
  end

  def test_the_settings_cannot_be_changed_after_boot
    config = Wurk::Configuration.new
    config.freeze!

    assert_raises(FrozenError) { config.api_rate_limit = 10 }
    assert_raises(FrozenError) { config.api_rate_limit_interval = :hour }
  end

  private

  def limited!(count, interval: :minute)
    @config = build_config do |cfg|
      cfg.api_rate_limit = count
      cfg.api_rate_limit_interval = interval
    end
  end

  def app = @app ||= Wurk::API::App.new(config: config)

  def config
    @config ||= build_config
  end

  def build_config
    Wurk::Configuration.new.tap do |cfg|
      [TOKEN, OTHER_TOKEN, REGISTRY_TOKEN].each { |token| cfg.api_token(token, scopes: %i[admin]) }
      yield cfg if block_given?
    end
  end

  def limiter_name(token)
    "#{Wurk::API::Throttle::NAME_PREFIX}#{Wurk::API::Auth.fingerprint(token)}"
  end

  def limiter_keys = @pool.with { |conn| conn.call('KEYS', 'lmtr-w:*') }

  def registered_limiters = @pool.with { |conn| conn.call('SMEMBERS', Wurk::Limiter::LIST_KEY) }

  def get(path, token: TOKEN) = request('GET', path, token: token)
  def post(path, token: TOKEN) = request('POST', path, token: token)

  def request(method, path, token:)
    env = {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => '',
      'QUERY_STRING' => '',
      'CONTENT_TYPE' => 'application/json',
      'CONTENT_LENGTH' => '0',
      'rack.input' => StringIO.new,
      'rack.errors' => StringIO.new
    }
    env['HTTP_AUTHORIZATION'] = "Bearer #{token}" if token
    status, headers, body = app.call(env)
    [status, headers, JSON.parse(body.join)]
  end
end
