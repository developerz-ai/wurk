# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'json'

# Slice 07, task 49 — how `WURK_WEB_READ_ONLY=1` reaches the machine plane,
# proven under a booted host rather than by handing the app a Rack env.
#
# The rule itself (every write refused, `enqueue` included) is pinned in
# test/unit/api_read_only_test.rb. What only a real mount can show is which
# deployments inherit it: nested in the engine the API sits behind
# `Wurk::Web::Authorization` and is part of the dashboard's deployment; mounted
# on its own path it is not, and says so for itself or not at all.
#
# Mutates the process-wide `Wurk.configuration` and `Wurk::Web.config`, so —
# like api_mount_modes_test.rb — this class does not declare `parallelize_me!`
# and serializes its own methods through GLOBAL_STATE_MUTEX.
class ApiReadOnlyEngineTest < Wurk::Test::EngineCase
  TOKEN = 'engine-api-read-only-token-dddddd'

  ENGINE_MOUNT = '/wurk/api'
  SEPARATE_MOUNT = '/wurk-api'

  def run(*)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize { super }
  end

  def setup
    super
    @queue = "q-#{Process.pid}-#{object_id}"
    Wurk.configuration.api_token(TOKEN, scopes: %i[admin])
    ::Wurk::Web.configure { |c| c.read_only = true }
  end

  def teardown
    Wurk.configuration.api_tokens.delete(TOKEN)
    Wurk.configuration.api_read_only = nil
    ::Wurk::Web.config.reset!
  ensure
    super
  end

  # --- mode 1 inherits ----------------------------------------------------

  def test_the_engine_nested_mount_inherits_the_dashboard_freeze
    response = post("#{ENGINE_MOUNT}/v1/queues/#{@queue}/pause")

    assert_equal 403, response.status
    assert_equal 'read_only', JSON.parse(response.body)['type']
  end

  # The reason the middleware hands the decision down instead of answering:
  # its own refusal is the string "Read-only mode" in text/plain, which a
  # machine client can neither branch on nor log usefully.
  def test_the_inherited_refusal_is_a_problem_document
    response = post("#{ENGINE_MOUNT}/v1/jobs")

    assert_equal 'application/problem+json', response.content_type
    body = JSON.parse(response.body)

    assert_equal 'Read-Only Mode', body['title']
    assert_equal "#{ENGINE_MOUNT}/v1/jobs", body['instance']
    refute_includes response.body, 'Read-only mode'
  end

  def test_the_engine_nested_mount_still_answers_reads
    response = get("#{ENGINE_MOUNT}/v1/queues")

    assert_equal 200, response.status
    assert_same true, JSON.parse(get("#{ENGINE_MOUNT}/v1").body)['read_only']
  end

  # The other half of "inherits": with the dashboard live, the stamp must not
  # be there. A middleware that marked every API request would freeze mode 1
  # permanently and still pass every assertion above.
  def test_the_engine_nested_mount_is_live_while_the_dashboard_is
    ::Wurk::Web.configure { |c| c.read_only = false }

    response = post("#{ENGINE_MOUNT}/v1/queues/#{@queue}/pause")

    assert_equal 200, response.status
  ensure
    Wurk::Queue.new(@queue).unpause!
  end

  # Handing API paths past the read-only arm leaves them behind the host's own
  # gate: `Wurk::Web.use`/`authorization` guard the mount, and a machine client
  # reaching this path chose that mount. Skipping both checks rather than the
  # one would have opened a dashboard behind Devise to any bearer token.
  def test_the_engine_nested_mount_still_obeys_the_hosts_authorization_hook
    ::Wurk::Web.configure { |c| c.authorization { |_env, _method, _path| false } }

    response = get("#{ENGINE_MOUNT}/v1/queues")

    assert_equal 403, response.status
    assert_equal 'Forbidden', response.body
  end

  # Handing API paths past the read-only arm must not change what the arm does
  # for the dashboard the middleware was written for.
  def test_the_dashboards_own_mutations_are_refused_exactly_as_before
    response = post("/wurk/api/queues/#{@queue}/pause")

    assert_equal 403, response.status
    assert_equal 'Read-only mode', response.body
    assert_includes response.content_type, 'text/plain'
  end

  # --- modes 2 and 3 opt in -----------------------------------------------

  # No engine in front, so nothing stamps the env: a separately mounted API is
  # a different deployment and the dashboard's flag does not reach it.
  def test_a_separate_mount_does_not_inherit_the_dashboard_freeze
    response = post("#{SEPARATE_MOUNT}/v1/queues/#{@queue}/pause")

    assert_equal 200, response.status
    assert_same false, JSON.parse(get("#{SEPARATE_MOUNT}/v1").body)['read_only']
  ensure
    Wurk::Queue.new(@queue).unpause!
  end

  def test_a_separate_mount_freezes_when_it_opts_in
    Wurk.configuration.api_read_only = true

    response = post("#{SEPARATE_MOUNT}/v1/queues/#{@queue}/pause")

    assert_equal 403, response.status
    assert_equal 'read_only', JSON.parse(response.body)['type']
  end

  # A viewer-only dashboard and a working producer on the same mount — the one
  # combination the inheritance would otherwise make unreachable.
  def test_the_engine_nested_mount_can_opt_out_of_the_inherited_freeze
    Wurk.configuration.api_read_only = false

    response = post("#{ENGINE_MOUNT}/v1/queues/#{@queue}/pause")

    assert_equal 200, response.status
  ensure
    Wurk::Queue.new(@queue).unpause!
  end

  private

  def rails
    @rails ||= ::Rack::Test::Session.new(::Rails.application).tap { |s| s.header('Authorization', "Bearer #{TOKEN}") }
  end

  def get(path) = rails.get(path, {}, 'HTTP_ACCEPT' => 'application/json')
  def post(path) = rails.post(path, {}, 'HTTP_ACCEPT' => 'application/json')
end
