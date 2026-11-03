# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'json'
require 'openssl'
require 'securerandom'
require 'stringio'

# Parity oracle for the machine-facing HTTP API — Wurk's `/v1` plane.
#
# Upstream Sidekiq has no HTTP API at all, so there is no upstream behaviour to
# compare against: docs/idea/parity-divergences.md records this plane as
# "Spec: no upstream equivalent (Wurk REST API)". These assertions are
# therefore source-first against Wurk's own contract, and they are the oracles
# the conformance inventory cites for the `web.api-*` cases.
#
# Sources enforced:
# - docs/api-http.md L8-L12 — "Off unless a token is configured": with no token
#   registered the plane does not exist — no route, no port, no challenge.
# - docs/api-http.md L48-L51 — nothing hardcodes a prefix; every URL the API
#   emits, the discovery document's `url` among them, comes from SCRIPT_NAME.
# - docs/api-http.md L143-L145 — a bearer credential is compared in constant
#   time against every registered token, with no early exit on a match.
# - docs/api-http.md L153 — `admin` implies `enqueue` and `read`, plus the
#   destructive routes.
# - docs/api-http.md L160 — no credential presented is a 401 with a Bearer
#   challenge.
# - docs/api-http.md L162 — a valid credential without the route's scope is a
#   403 naming the scope, never a 404 hiding the route.
# - docs/api-http.md L265-L266 — the window a key is remembered for is
#   `config.api_idempotency_ttl` seconds, 3600 by default.
# - docs/idea/parity-divergences.md L745-L747 — an unknown write outcome keeps
#   the `Idempotency-Key` pending until its TTL, so a client retry is told
#   "in progress" instead of enqueueing a second copy.
#
# Driven the way a host drives it: a Rack env in, a Rack triple out, over real
# Redis. The plane is plain Rack under lib/ and never touches Rails.
class WebApiParityTest < Wurk::Test::UnitCase
  parallelize_me!

  READ_TOKEN = 'web-api-parity-read-token-0123456789'
  ADMIN_TOKEN = 'web-api-parity-admin-token-0123456789'
  UNKNOWN_TOKEN = 'web-api-parity-unknown-token-0123456789'

  # The documented default window an `Idempotency-Key` stays pending for.
  IDEMPOTENCY_TTL = 3_600

  def setup
    super
    @namespace = SecureRandom.hex(6)
    @queue = "web-api-parity-#{@namespace}"
    @class_name = "WebApiParityJob#{@namespace}"
  end

  # --- Off unless a token is configured -----------------------------------

  # "None of this exists": an app with no token registered has to look exactly
  # like an app that was never mounted — the same answer for every address,
  # and no bearer challenge advertising a surface that is not there.
  def test_the_api_is_absent_without_a_registered_token
    config = Wurk::Configuration.new
    app = Wurk::API::App.new(config: config)

    refute_predicate config, :api_enabled?
    assert_empty config.api_tokens

    %w[/v1 /v1/queues /v1/jobs /v2/jobs].each do |path|
      status, headers, body = dispatch(app, env_for('GET', path))

      assert_equal 404, status, "GET #{path} answered as if the API existed"
      assert_equal 'not_found', body['type']
      refute headers.key?('www-authenticate'), "GET #{path} advertised a bearer challenge"
    end

    status, headers, = dispatch(app, env_for('POST', '/v1/jobs', body: job_body))

    assert_equal 404, status, 'the produce route answered as if the API existed'
    refute headers.key?('www-authenticate')
  end

  # --- Bearer credentials --------------------------------------------------

  # RFC 6750's challenge, verbatim: the realm names this server, and a client
  # that presented nothing is not told its credential was wrong.
  def test_a_missing_bearer_token_is_challenged
    status, headers, body = request('GET', '/v1/queues', token: nil)

    assert_equal 401, status
    assert_equal 'Bearer realm="wurk"', headers['www-authenticate']
    assert_equal 'unauthorized', body['type']
  end

  # "Compared in constant time against every registered token — no early exit
  # on a match": the walk does not stop at the token that matched, and every
  # comparison is a constant-time compare over operands of a single length,
  # so the clock can neither name the token that matched nor say how much of
  # one a caller guessed right.
  def test_every_registered_token_is_compared_before_a_match_is_accepted
    config = Wurk::Configuration.new
    config.api_token(READ_TOKEN, scopes: %i[read])
    config.api_token(ADMIN_TOKEN, scopes: %i[admin])
    compared = ComparedTokens.new(config.api_tokens)
    config[:api_tokens] = compared
    app = Wurk::API::App.new(config: config)

    recording_comparisons do |comparisons|
      status, = dispatch(app, env_for('GET', '/v1/queues', token: READ_TOKEN))

      assert_equal 200, status
      assert_equal 2, compared.count, 'the match ended the walk'
      assert_equal 2, comparisons.size, 'the credential was not compared in constant time'

      status, = dispatch(app, env_for('GET', '/v1/queues', token: UNKNOWN_TOKEN))

      assert_equal 401, status
      assert_equal 2, compared.count, 'a miss walked less than the whole table'
      assert_equal 4, comparisons.size, 'a miss was not compared in constant time'

      sizes = comparisons.flat_map { |left, right| [left.bytesize, right.bytesize] }

      assert_equal 1, sizes.uniq.size, 'the constant-time compare saw operands of different lengths'
    end
  end

  # The recorder that counts the comparisons is a process-global swap on
  # OpenSSL, so it must not count a comparison made by another thread: the
  # count is the evidence that the lookup walked the whole table, and a
  # credential presented on a sibling thread would inflate it.
  def test_the_comparison_recorder_ignores_other_threads
    recording_comparisons do |comparisons|
      Thread.new { OpenSSL.fixed_length_secure_compare('a' * 32, 'b' * 32) }.join

      assert_empty comparisons, 'a comparison from another thread was counted'
    end
  end

  # --- Scopes --------------------------------------------------------------

  # A valid credential that lacks the route's scope is told which scope it
  # lacks. A 404 would hide the route from a caller that has already proved
  # who it is, and leave it hunting for the wrong problem.
  def test_a_token_without_the_required_scope_is_refused
    status, headers, body = request('POST', '/v1/jobs', token: READ_TOKEN, body: job_body)

    assert_equal 403, status
    assert_equal 'insufficient_scope', body['type']
    assert_equal 'enqueue', body['required_scope']
    assert_equal 'Bearer realm="wurk", error="insufficient_scope", scope="enqueue"', headers['www-authenticate']
    assert_empty queued_payloads
  end

  # `admin` is everything: it implies `enqueue` and `read`, and it carries the
  # destructive routes too. The read-scoped token is refused on the very same
  # routes, so the contrast is the implication rather than a route table.
  def test_the_admin_scope_implies_enqueue_and_read
    status, _headers, body = request('POST', '/v1/jobs', token: ADMIN_TOKEN, body: job_body)

    assert_equal 201, status
    refute_nil body['jid']

    status, = request('GET', '/v1/queues', token: ADMIN_TOKEN)

    assert_equal 200, status, 'admin did not imply read'

    status, = request('POST', '/v1/queues/default/pause', token: ADMIN_TOKEN)

    assert_equal 200, status, 'admin did not carry the destructive routes'

    status, _headers, body = request('DELETE', '/v1/jobs/0123456789abcdef01234567', token: ADMIN_TOKEN)

    assert_equal 404, status
    assert_equal 'job_not_found', body['type'], 'the destructive route was not reached'
  end

  # --- Mounting ------------------------------------------------------------

  # One implementation serves three mounts, so no URL may be hardcoded: the
  # discovery document's `url` is the prefix the request actually arrived
  # through, and a client can trust it as the base for everything after it.
  def test_the_discovery_document_derives_its_url_from_the_mount_prefix
    _status, _headers, body = request('GET', '/v1', script_name: '/wurk/api')

    assert_equal '/wurk/api/v1', body['url']

    _status, _headers, body = request('GET', '/v1', script_name: '/wurk-api')

    assert_equal '/wurk-api/v1', body['url']

    _status, _headers, body = request('GET', '/v1')

    assert_equal '/v1', body['url']
  end

  # --- Idempotency ---------------------------------------------------------

  # A lost reply is an outcome nobody can classify: the write may or may not
  # have landed. Releasing the key there is exactly how a retry double-enqueues,
  # so the claim stays pending until its TTL and the retry is told "in
  # progress" instead.
  def test_a_lost_reply_keeps_the_idempotency_key_pending_until_its_ttl
    started = monotonic_now
    status, = Wurk::Client.via(LostReplyPool.new(pool)) do
      request('POST', '/v1/jobs', token: ADMIN_TOKEN, body: job_body, key: 'lost-reply')
    end

    assert_equal 500, status
    assert_equal 1, queued_payloads.size, 'the write landed before its reply was lost'

    claims = idempotency_claims

    assert_equal 1, claims.size, 'the claim was released on an unknown outcome'
    ttl = ttl_of(claims.first)

    # The claim is written with the documented window (3600s by default) and
    # the TTL is what is left of it, so the only slack the assertion may give
    # is the time that passed since the claim was taken. A claim given a
    # one-second life — or released early — fails here instead of passing the
    # retry below.
    elapsed = monotonic_now - started

    assert_operator ttl, :>, 0, 'the pending claim has no lifetime left'
    assert_operator ttl, :<=, IDEMPOTENCY_TTL, 'the pending claim outlives the documented window'
    assert_operator ttl, :>=, IDEMPOTENCY_TTL - elapsed.ceil,
                    "the pending claim had #{ttl}s left, not the documented #{IDEMPOTENCY_TTL}s window"

    status, headers, body = request('POST', '/v1/jobs', token: ADMIN_TOKEN, body: job_body, key: 'lost-reply')

    assert_equal 409, status
    assert_equal 'request_in_progress', body['type']
    assert_equal '1', headers['retry-after']
    assert_equal 1, queued_payloads.size, 'the retry enqueued a second copy'
  end

  private

  # Counts how many registered tokens a lookup compared. The documented
  # contract is that a lookup walks the whole table, so this count is the only
  # observable that can tell that walk from a lookup that stopped at the hit.
  class ComparedTokens < Hash
    attr_reader :count

    def initialize(pairs)
      super()
      pairs.each { |token, scopes| self[token] = scopes }
      @count = 0
    end

    def each(&block)
      @count = 0
      super do |token, scopes|
        @count += 1
        block.call(token, scopes)
      end
    end
  end

  # The write lands and the reply never comes back: the one outcome neither
  # the producer nor the server can classify.
  class LostReplyPool
    def initialize(real)
      @real = real
    end

    def with(...)
      @real.with(...)
      raise RedisClient::ReadTimeoutError, 'the reply never arrived'
    end
  end

  # Counts the constant-time comparisons a lookup makes and keeps the operands
  # it saw. Minitest 6 dropped minitest/mock, so the compare is swapped for a
  # recorder on OpenSSL's singleton and restored afterwards.
  #
  # The swap is process-global, so the recorder keeps only the comparisons
  # made by the thread that installed it: a credential presented on another
  # thread while the recorder is live cannot inflate the count.
  def recording_comparisons
    comparisons = []
    original = OpenSSL.method(:fixed_length_secure_compare)
    owner = Thread.current
    OpenSSL.define_singleton_method(:fixed_length_secure_compare) do |left, right|
      comparisons << [left, right] if Thread.current.equal?(owner)
      original.call(left, right)
    end
    yield comparisons
  ensure
    OpenSSL.define_singleton_method(:fixed_length_secure_compare, original)
  end

  def app
    @app ||= Wurk::API::App.new(config: config)
  end

  def config
    @config ||= Wurk::Configuration.new.tap do |cfg|
      cfg.api_token(READ_TOKEN, scopes: %i[read])
      cfg.api_token(ADMIN_TOKEN, scopes: %i[admin])
    end
  end

  def pool = Wurk.configuration.redis_pool

  def job_body
    JSON.generate('class' => @class_name, 'args' => [], 'queue' => @queue)
  end

  def queued_payloads
    pool.with { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }
  end

  def idempotency_claims
    pool.with { |conn| conn.call('KEYS', "#{Wurk::Keys::IDEMPOTENCY_PREFIX}*") }
  end

  def ttl_of(key) = pool.with { |conn| conn.call('TTL', key) }

  def monotonic_now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

  def request(method, path, token: READ_TOKEN, body: '', script_name: '', key: nil)
    dispatch(app, env_for(method, path, token: token, body: body, script_name: script_name, key: key))
  end

  def dispatch(app, env)
    status, headers, raw = app.call(env)
    [status, headers, JSON.parse(raw.join)]
  end

  def env_for(method, path, token: nil, body: '', script_name: '', key: nil)
    env = {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => script_name,
      'QUERY_STRING' => '',
      'CONTENT_TYPE' => 'application/json',
      'CONTENT_LENGTH' => body.bytesize.to_s,
      'rack.input' => StringIO.new(body),
      'rack.errors' => StringIO.new
    }
    env['HTTP_AUTHORIZATION'] = "Bearer #{token}" if token
    env['HTTP_IDEMPOTENCY_KEY'] = key if key
    env
  end
end
