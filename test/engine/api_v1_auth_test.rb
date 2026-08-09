# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'wurk/api/app'
require 'json'
require 'stringio'

# Slice 07, task 45 — the auth gate proven against the actual global
# `Wurk.configuration` a booted host app resolves at request time.
# `Wurk::API.call` (api.rb) and `Wurk::API::App#config` both read
# `::Wurk.configuration` whenever no config is injected — the path every real
# `mount Wurk::API => '/wurk-api'` or a conditionally mounted engine takes.
# The exhaustive scheme/scope matrix and the credential registry itself are
# already pinned in isolation in test/unit/api_auth_test.rb; this file
# re-proves the four load-bearing claims the plan's "headline" test list
# calls out, but under a fully booted Rails host (test/dummy) against the
# process-wide singleton rather than a Configuration built just for the test.
#
# Mutates `Wurk.configuration.api_tokens` — the same process-global registry
# every other engine test's dummy app shares — so this class does not declare
# `parallelize_me!` (same reasoning as api_mutations_test.rb) and serializes
# its own test methods through GLOBAL_STATE_MUTEX, the mutex every other
# process-global-state test in this suite uses.
class ApiV1AuthTest < Wurk::Test::EngineCase
  READ_TOKEN  = 'engine-api-v1-read-token-aaaaaaaaa'
  ADMIN_TOKEN = 'engine-api-v1-admin-token-bbbbbbbbb'

  def app = ::Wurk::API

  def run(*)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize { super }
  end

  def teardown
    Wurk.configuration.api_tokens.delete(READ_TOKEN)
    Wurk.configuration.api_tokens.delete(ADMIN_TOKEN)
  ensure
    super
  end

  # The 404 is the point: an app mounted without a token has to look exactly
  # like an app that was never mounted at all — not a real surface guarded by
  # a 401.
  def test_no_token_configured_answers_404_not_401
    get '/v1/jobs'

    assert_equal 404, last_response.status
    assert_equal 'not_found', json_body['type']
    refute last_response.headers.key?('www-authenticate')
  end

  def test_a_missing_credential_is_401_once_a_token_exists
    Wurk.configuration.api_token(READ_TOKEN, scopes: %i[read])

    get '/v1'

    assert_equal 401, last_response.status
    assert_equal 'unauthorized', json_body['type']
  end

  def test_an_unregistered_token_is_401
    Wurk.configuration.api_token(READ_TOKEN, scopes: %i[read])
    header 'Authorization', 'Bearer not-a-registered-token-00000'

    get '/v1'

    assert_equal 401, last_response.status
    assert_equal 'The bearer token presented is not valid.', json_body['detail']
  end

  def test_a_token_outside_the_routes_scope_is_403
    Wurk.configuration.api_token(READ_TOKEN, scopes: %i[read])
    header 'Authorization', "Bearer #{READ_TOKEN}"

    post '/v1/jobs', JSON.generate('class' => 'EngineAuthDeniedJob', 'args' => []),
         'CONTENT_TYPE' => 'application/json'

    assert_equal 403, last_response.status
    assert_equal 'insufficient_scope', json_body['type']
    assert_equal 'enqueue', json_body['required_scope']
  end

  # Constant-time comparison, proven against the real global registry rather
  # than a table built just for this test: every entry is still visited even
  # after the presented token has already matched one earlier in the table.
  def test_every_registered_token_is_walked_even_after_a_match
    Wurk.configuration.api_token(READ_TOKEN, scopes: %i[read])
    Wurk.configuration.api_token(ADMIN_TOKEN, scopes: %i[admin])
    tokens = CountingTokens.new(Wurk.configuration.api_tokens)

    principal = Wurk::API::Auth.authenticate(fake_request("Bearer #{READ_TOKEN}"), FakeConfig.new(tokens))

    assert_equal %i[read], principal.scopes
    assert_equal 2, tokens.visited
  end

  FakeConfig = Struct.new(:api_tokens)

  private

  # Records how many entries a lookup walked — a `tokens[presented]` hash
  # regression would visit none of them.
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

  def json_body = ::JSON.parse(last_response.body)

  def fake_request(authorization)
    Wurk::API::Request.new(
      'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/v1', 'SCRIPT_NAME' => '', 'QUERY_STRING' => '',
      'HTTP_AUTHORIZATION' => authorization, 'rack.input' => StringIO.new, 'rack.errors' => StringIO.new
    )
  end
end
