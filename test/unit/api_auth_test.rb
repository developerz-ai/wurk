# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'stringio'

# Slice 07 — bearer-token auth for the machine-facing HTTP API. The gate every
# other API slice sits behind: no token registered means the API does not
# exist, and nothing under /v1 answers without one.
class ApiAuthTest < Wurk::Test::UnitCase
  parallelize_me!

  LIB = File.expand_path('../../lib', __dir__)

  READ_TOKEN    = 'read-token-aaaaaaaaaaaaaaaaaa'
  ENQUEUE_TOKEN = 'enqueue-token-bbbbbbbbbbbbbbb'
  ADMIN_TOKEN   = 'admin-token-cccccccccccccccccc'

  # --- The registry: no token, no API ------------------------------------

  def test_a_fresh_configuration_registers_no_tokens
    fresh = Wurk::Configuration.new

    assert_empty fresh.api_tokens
    refute_predicate fresh, :api_enabled?
  end

  def test_registering_a_token_brings_the_api_into_existence
    assert_predicate config, :api_enabled?
    assert_equal %i[read], config.api_tokens[READ_TOKEN]
  end

  # The 404 is the point: an app mounted without a token has to look exactly
  # like an app that was never mounted, not like one guarding a real surface.
  def test_no_token_configured_answers_404_not_401
    status, headers, body = request('GET', '/v1', token: ADMIN_TOKEN, app: unconfigured_app)

    assert_equal 404, status
    assert_equal 'not_found', body['type']
    refute headers.key?('www-authenticate')
  end

  def test_no_token_configured_hides_every_address_alike
    %w[/v1 /v1/reads /v1/nope /v2/reads].each do |path|
      _status, _headers, body = request('GET', path, app: unconfigured_app)

      assert_equal 'not_found', body['type'], "#{path} leaked which addresses exist"
    end
  end

  # --- Authentication ------------------------------------------------------

  def test_a_missing_credential_is_challenged_without_claiming_one_was_wrong
    status, headers, body = request('GET', '/v1/reads')

    assert_equal 401, status
    assert_equal 'unauthorized', body['type']
    assert_equal 'Bearer realm="wurk"', headers['www-authenticate']
    assert_equal 'A bearer token is required.', body['detail']
  end

  def test_an_unknown_token_is_rejected_as_invalid
    status, headers, body = request('GET', '/v1/reads', token: 'not-a-registered-token-000000')

    assert_equal 401, status
    assert_equal 'Bearer realm="wurk", error="invalid_token"', headers['www-authenticate']
    assert_equal 'The bearer token presented is not valid.', body['detail']
  end

  def test_a_token_of_a_different_length_is_rejected_like_any_other
    status, = request('GET', '/v1/reads', token: 'x' * 400)

    assert_equal 401, status
  end

  def test_another_scheme_or_a_bare_scheme_never_authenticates
    ['Basic abc123', 'Bearer', 'Bearer ', READ_TOKEN, "Token #{READ_TOKEN}"].each do |header|
      status, = request('GET', '/v1/reads', authorization: header)

      assert_equal 401, status, "#{header.inspect} was accepted"
    end
  end

  # RFC 9110 §11.1: the scheme is case-insensitive. The credential is not.
  def test_the_scheme_is_case_insensitive_and_the_token_is_not
    status, = request('GET', '/v1/reads', authorization: "bEaReR #{READ_TOKEN}")

    assert_equal 200, status

    status, = request('GET', '/v1/reads', token: READ_TOKEN.upcase)

    assert_equal 401, status
  end

  def test_a_registered_token_reaches_the_handler
    status, _headers, body = request('GET', '/v1/reads', token: READ_TOKEN)

    assert_equal 200, status
    assert_equal 'read', body['ok']
  end

  # --- Scopes --------------------------------------------------------------

  def test_a_token_outside_the_routes_scope_is_403_with_the_scope_it_lacks
    status, headers, body = request('POST', '/v1/enqueues', token: READ_TOKEN)

    assert_equal 403, status
    assert_equal 'insufficient_scope', body['type']
    assert_equal 'enqueue', body['required_scope']
    assert_equal 'Bearer realm="wurk", error="insufficient_scope", scope="enqueue"', headers['www-authenticate']
  end

  def test_scopes_are_not_interchangeable
    status, = request('GET', '/v1/reads', token: ENQUEUE_TOKEN)

    assert_equal 403, status
  end

  def test_admin_grants_the_other_scopes
    %w[/v1/reads /v1/admins].each do |path|
      status, = request(path == '/v1/admins' ? 'POST' : 'GET', path, token: ADMIN_TOKEN)

      assert_equal 200, status, "admin was refused #{path}"
    end

    status, = request('POST', '/v1/enqueues', token: ADMIN_TOKEN)

    assert_equal 201, status
  end

  def test_read_and_enqueue_do_not_grant_admin
    [READ_TOKEN, ENQUEUE_TOKEN].each do |token|
      status, = request('POST', '/v1/admins', token: token)

      assert_equal 403, status
    end
  end

  # The discovery document is the one route any authenticated client may read:
  # a producer has to confirm the contract before it trusts what it posts to.
  def test_the_discovery_document_answers_any_authenticated_token
    [READ_TOKEN, ENQUEUE_TOKEN, ADMIN_TOKEN].each do |token|
      status, = request('GET', '/v1', token: token)

      assert_equal 200, status
    end
  end

  # --- Ordering: authenticate before saying anything about addresses -------

  def test_an_unauthenticated_client_cannot_enumerate_routes
    status, = request('GET', '/v1/nope')

    assert_equal 401, status

    _status, _headers, body = request('GET', '/v1/nope', token: READ_TOKEN)

    assert_equal 'not_found', body['type']
  end

  def test_an_unauthenticated_client_cannot_enumerate_versions
    status, = request('GET', '/v2/reads')

    assert_equal 401, status

    _status, _headers, body = request('GET', '/v2/reads', token: READ_TOKEN)

    assert_equal 'unsupported_api_version', body['type']
  end

  def test_the_wrong_verb_still_authenticates_first
    status, = request('POST', '/v1/reads')

    assert_equal 401, status

    status, = request('POST', '/v1/reads', token: READ_TOKEN)

    assert_equal 405, status
  end

  # --- Never the dashboard plane ------------------------------------------

  # same_origin_guard.rb denies every unsafe request that doesn't carry
  # `Sec-Fetch-Site: same-origin` — a header only a browser sets. A Python or
  # Go producer sends none, so the API must not consult it: these POSTs carry
  # no fetch metadata (and then hostile fetch metadata) and still go through.
  def test_a_machine_client_needs_no_browser_fetch_metadata
    status, = request('POST', '/v1/enqueues', token: ENQUEUE_TOKEN)

    assert_equal 201, status

    status, = request('POST', '/v1/enqueues', token: ENQUEUE_TOKEN, 'HTTP_SEC_FETCH_SITE' => 'cross-site')

    assert_equal 201, status
  end

  # --- Constant-time comparison -------------------------------------------

  # No early return on a hit: the first token registered is the one presented,
  # and the walk still visits the rest. A Hash lookup would visit none.
  def test_every_registered_token_is_compared_even_after_a_match
    tokens = CountingTokens.new([[READ_TOKEN, %i[read]], [ADMIN_TOKEN, %i[admin]]])
    principal = Wurk::API::Auth.authenticate(rack_request("Bearer #{READ_TOKEN}"), FakeConfig.new(tokens))

    assert_equal %i[read], principal.scopes
    assert_equal 2, tokens.visited
  end

  def test_a_miss_also_walks_the_whole_table
    tokens = CountingTokens.new([[READ_TOKEN, %i[read]], [ADMIN_TOKEN, %i[admin]]])

    assert_nil Wurk::API::Auth.authenticate(rack_request('Bearer nope-nope-nope-nope-nope'), FakeConfig.new(tokens))
    assert_equal 2, tokens.visited
  end

  # Constant-time comparison leaves no runtime signature to assert against; a
  # test can only pin that it is still the primitive in use. The walk tests
  # above catch a regression to a Hash lookup — this one catches `==`, and the
  # bytesize pre-check that makes Rack::Utils.secure_compare leak token length.
  def test_token_comparison_stays_constant_time
    code = File.readlines(File.expand_path('../../lib/wurk/api/auth.rb', __dir__)).grep_v(/^\s*#/).join

    assert_includes code, 'OpenSSL.fixed_length_secure_compare'
    refute_match(/tokens\[|\bbytesize\b/, code)
  end

  # --- Declaring a credential ---------------------------------------------

  def test_a_token_short_enough_to_have_been_typed_is_refused
    error = assert_raises(ArgumentError) { Wurk::Configuration.new.api_token('short', scopes: %i[read]) }

    assert_match(/at least 20 characters/, error.message)
    assert_raises(ArgumentError) { Wurk::Configuration.new.api_token(nil, scopes: %i[read]) }
  end

  def test_a_token_that_cannot_survive_a_header_is_refused
    ["with space#{'a' * 20}", "tab\t#{'a' * 20}", "nul\0#{'a' * 20}", "hí#{'a' * 20}"].each do |value|
      assert_raises(ArgumentError, "#{value.inspect} was accepted") do
        Wurk::Configuration.new.api_token(value, scopes: %i[read])
      end
    end
  end

  def test_an_unknown_or_empty_scope_fails_where_it_is_declared
    error = assert_raises(ArgumentError) { Wurk::Configuration.new.api_token(READ_TOKEN, scopes: %i[reed]) }

    assert_match(/unknown api_token scope/, error.message)
    assert_match(/enqueue/, error.message)
    assert_raises(ArgumentError) { Wurk::Configuration.new.api_token(READ_TOKEN, scopes: []) }
  end

  def test_scopes_are_normalized_and_frozen
    fresh = Wurk::Configuration.new
    fresh.api_token(READ_TOKEN, scopes: ['read', :read, 'admin'])

    assert_equal %i[read admin], fresh.api_tokens[READ_TOKEN]
    assert_predicate fresh.api_tokens[READ_TOKEN], :frozen?
  end

  def test_re_registering_a_token_replaces_its_scopes
    fresh = Wurk::Configuration.new
    fresh.api_token(READ_TOKEN, scopes: %i[read])
    fresh.api_token(READ_TOKEN, scopes: %i[admin])

    assert_equal({ READ_TOKEN => %i[admin] }, fresh.api_tokens)
  end

  def test_a_frozen_configuration_refuses_new_tokens
    frozen = Wurk::Configuration.new.tap(&:freeze!)

    assert_raises(FrozenError) { frozen.api_token(READ_TOKEN, scopes: %i[read]) }
  end

  def test_the_registry_is_not_shared_between_configurations
    config.api_tokens

    assert_empty Wurk::Configuration.new.api_tokens
  end

  # The additive invariant, config-side: registering a token is what pulls the
  # auth module (and openssl/digest with it) in. A host that serves no HTTP API
  # carries none of it in a swarm child's pre-fork heap. Subprocess, because
  # this process has already required it.
  def test_registering_a_token_is_what_loads_the_auth_module
    probe = 'print $LOADED_FEATURES.grep(%r{wurk/api/auth\.rb\z}).size'

    assert_equal '0', ruby("require 'wurk'; #{probe}")
    assert_equal '1', ruby(<<~RUBY)
      require 'wurk'
      Wurk.configuration.api_token('#{READ_TOKEN}', scopes: %i[read])
      #{probe}
    RUBY
  end

  # --- Principal -----------------------------------------------------------

  def test_a_principal_reports_only_what_it_was_granted
    principal = Wurk::API::Auth::Principal.new('0123456789abcdef0123456789abcdef', %i[read])

    assert principal.permits?(:read)
    assert principal.permits?(Wurk::API::Auth::ANY)
    refute principal.permits?(:enqueue)
    refute principal.permits?(:admin)
  end

  FakeConfig = Struct.new(:api_tokens)

  private

  # One route per scope, so a token can be pointed at exactly the one it lacks.
  class ScopedApp < Wurk::API::App
    private

    def draw(router)
      router.get('/', scope: Wurk::API::Auth::ANY) { |_request| Wurk::API::Response.json(200, ok: 'any') }
      router.get('/reads', scope: :read) { |_request| Wurk::API::Response.json(200, ok: 'read') }
      router.post('/enqueues', scope: :enqueue) { |_request| Wurk::API::Response.json(201, ok: 'enqueue') }
      router.post('/admins', scope: :admin) { |_request| Wurk::API::Response.json(200, ok: 'admin') }
    end
  end

  # Records how many entries a lookup walked. A `tokens[presented]` regression
  # visits none of them.
  class CountingTokens
    attr_reader :visited

    def initialize(pairs)
      @pairs = pairs
      @visited = 0
    end

    def empty? = @pairs.empty?

    def each
      @pairs.each do |token, scopes|
        @visited += 1
        yield(token, scopes)
      end
    end
  end

  def config
    @config ||= Wurk::Configuration.new.tap do |cfg|
      cfg.api_token(READ_TOKEN, scopes: %i[read])
      cfg.api_token(ENQUEUE_TOKEN, scopes: %i[enqueue])
      cfg.api_token(ADMIN_TOKEN, scopes: %i[admin])
    end
  end

  def unconfigured_app = ScopedApp.new(config: Wurk::Configuration.new)

  def request(method, path, token: nil, authorization: nil, app: nil, **env_extra)
    env = env_for(method, path).merge(env_extra)
    credential = authorization || (token && "Bearer #{token}")
    env['HTTP_AUTHORIZATION'] = credential if credential
    status, headers, body = (app || ScopedApp.new(config: config)).call(env)
    [status, headers, JSON.parse(body.join)]
  end

  def ruby(script)
    IO.popen([RbConfig.ruby, '-I', LIB, '-e', script], err: %i[child out], &:read)
  end

  def rack_request(authorization)
    Wurk::API::Request.new(env_for('GET', '/v1').merge('HTTP_AUTHORIZATION' => authorization))
  end

  def env_for(method, path)
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => '',
      'QUERY_STRING' => '',
      'rack.input' => StringIO.new,
      'rack.errors' => StringIO.new
    }
  end
end
