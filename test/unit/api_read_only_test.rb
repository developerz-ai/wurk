# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'json'
require 'stringio'

# Slice 07, task 49 — what `read-only` means once there are two planes.
#
# The dashboard has frozen its non-safe verbs since the beginning
# (`WURK_WEB_READ_ONLY=1`). The decision pinned here is that the machine plane
# keeps the same rule rather than inventing a second one: every write is
# refused, `enqueue` as well as the destructive `admin` routes, so a viewer-only
# deployment cannot be talked into starting work by whoever holds a token.
#
# Which deployments that binds is the other half. Mounted inside the engine the
# API is part of the dashboard's deployment and inherits its flag; mounted on
# its own path or run standalone it is a different one and opts in explicitly.
# `Wurk::Web::Authorization` stamping that inheritance is proven under a real
# host in test/engine/api_read_only_test.rb; this file speaks about what the
# app does with the answer.
class ApiReadOnlyTest < Wurk::Test::UnitCase
  parallelize_me!

  ADMIN_TOKEN = 'api-read-only-admin-token-01234567'
  ENQUEUE_TOKEN = 'api-read-only-enqueue-token-012345'

  def setup
    super
    @ns = "#{Process.pid}_#{object_id}"
    @queue = "q-#{@ns}"
    @class_name = "ApiReadOnlyWorker#{@ns}"
    @pool = Wurk.configuration.redis_pool
  end

  # --- what it freezes ----------------------------------------------------

  # Every write the API has, under one flag. `enqueue` is in the list on
  # purpose: it is the case a scope-shaped rule would have let through.
  def test_every_write_is_refused
    frozen!
    writes = [
      ['POST', '/v1/jobs'],
      ['POST', '/v1/jobs/bulk'],
      ['DELETE', '/v1/jobs/abc123'],
      ['POST', "/v1/queues/#{@queue}/pause"],
      ['POST', "/v1/queues/#{@queue}/unpause"],
      ['POST', '/v1/processes/host:1:abc/quiet'],
      ['POST', '/v1/processes/host:1:abc/stop']
    ]

    writes.each do |method, path|
      status, headers, body = call(method, path)

      assert_equal 403, status, "#{method} #{path}"
      assert_equal 'application/problem+json', headers['content-type'], path
      assert_equal 'read_only', body['type'], path
      assert_equal 'Read-Only Mode', body['title'], path
      assert_equal path, body['instance'], path
    end
  end

  def test_a_frozen_deployment_still_answers_reads
    frozen!

    %w[/v1 /v1/stats /v1/queues /v1/swarm /v1/processes /v1/busy].each do |path|
      status, = call('GET', path)

      assert_equal 200, status, path
    end
  end

  def test_head_is_a_read
    frozen!
    status, = call('HEAD', '/v1/queues')

    assert_equal 200, status
  end

  # The refusal is a property of the deployment, not of the credential, so the
  # scope a token holds changes nothing about it. An `insufficient_scope` here
  # would send a producer to its operator for a grant that cannot help.
  def test_the_verdict_does_not_depend_on_the_scope_presented
    frozen!
    status, _headers, body = call('POST', '/v1/jobs', token: ENQUEUE_TOKEN)

    assert_equal 403, status
    assert_equal 'read_only', body['type']
  end

  # Nothing reaches Client, so nothing lands — the assertion the status code
  # alone would not make.
  def test_a_refused_enqueue_writes_nothing
    frozen!
    call('POST', '/v1/jobs', body: JSON.generate('class' => @class_name, 'args' => [], 'queue' => @queue))

    assert_empty queued_payloads
  end

  # Before routing, so a write to a path that does not exist is answered with
  # the fact that applies to every write here rather than a 404 that invites a
  # client to go looking for the right path.
  def test_a_write_to_an_unknown_path_is_refused_for_being_a_write
    frozen!
    status, _headers, body = call('POST', '/v1/nope')

    assert_equal 403, status
    assert_equal 'read_only', body['type']
  end

  # Authentication still runs first: a stranger learns nothing about the
  # deployment's mode, and the 401 is the same one a live deployment gives.
  def test_an_unauthenticated_write_is_still_401
    frozen!
    status, _headers, body = call('POST', '/v1/jobs', token: nil)

    assert_equal 401, status
    assert_equal 'unauthorized', body['type']
  end

  # --- which deployments it binds -----------------------------------------

  # Modes 2 and 3: no engine in front, nothing configured, so nothing is frozen.
  def test_a_standalone_mount_is_live_by_default
    status, = call('POST', "/v1/queues/#{@queue}/pause")

    assert_equal 200, status
  end

  # Mode 1: the engine stamps the dashboard's flag onto the Rack env.
  def test_an_engine_nested_mount_inherits_the_dashboard_flag
    status, _headers, body = call('POST', "/v1/queues/#{@queue}/pause", inherited: true)

    assert_equal 403, status
    assert_equal 'read_only', body['type']
  end

  # The same stamp on a mount that said it is live: an explicit `false` is the
  # host asking for a viewer-only dashboard and a working producer on one mount,
  # and it has to outrank what the engine passed down or it means nothing.
  def test_an_explicit_false_outranks_the_inherited_flag
    @config = build_config { |cfg| cfg.api_read_only = false }
    status, = call('POST', "/v1/queues/#{@queue}/pause", inherited: true)

    assert_equal 200, status
  end

  def test_an_explicit_true_freezes_a_mount_with_nothing_to_inherit
    @config = build_config { |cfg| cfg.api_read_only = true }
    status, = call('POST', "/v1/queues/#{@queue}/pause")

    assert_equal 403, status
  end

  # The only door mode 3 has — `wurk api` reads no Ruby config file.
  def test_the_environment_freezes_a_standalone_mount
    with_env('WURK_API_READ_ONLY', '1') do
      status, _headers, body = call('POST', "/v1/queues/#{@queue}/pause")

      assert_equal 403, status
      assert_equal 'read_only', body['type']
    end
  end

  def test_the_environment_variable_is_exact
    %w[0 true yes on].each do |value|
      with_env('WURK_API_READ_ONLY', value) do
        assert_equal 200, call('POST', "/v1/queues/#{@queue}/pause")[0], value
      end
    end
  end

  # --- the setting itself -------------------------------------------------

  def test_the_setting_is_three_state
    config = Wurk::Configuration.new

    assert_nil config.api_read_only

    config.api_read_only = true

    assert_same true, config.api_read_only

    config.api_read_only = false

    assert_same false, config.api_read_only

    config.api_read_only = nil

    assert_nil config.api_read_only
  end

  # `config.api_read_only = ENV['X']` is the shape a host reaches for, and
  # `!!'false'` is true.
  def test_a_string_that_means_off_does_not_turn_it_on
    ['', '0', 'false', 'no', 'off', ' OFF '].each do |value|
      config = Wurk::Configuration.new
      config.api_read_only = value

      assert_same false, config.api_read_only, value.inspect
    end
  end

  def test_a_string_that_means_on_turns_it_on
    %w[1 true yes on].each do |value|
      config = Wurk::Configuration.new
      config.api_read_only = value

      assert_same true, config.api_read_only, value.inspect
    end
  end

  def test_it_cannot_be_changed_after_boot
    config = Wurk::Configuration.new
    config.freeze!

    assert_raises(FrozenError) { config.api_read_only = true }
  end

  # --- telling a client in advance ----------------------------------------

  # A producer that can read "frozen" at startup fails in its own logs rather
  # than halfway through a batch.
  def test_the_discovery_document_reports_the_mode
    assert_same false, call('GET', '/v1')[2]['read_only']

    frozen!

    assert_same true, call('GET', '/v1')[2]['read_only']
  end

  def test_the_discovery_document_reports_an_inherited_freeze
    assert_same true, call('GET', '/v1', inherited: true)[2]['read_only']
  end

  private

  def frozen!
    @config = build_config { |cfg| cfg.api_read_only = true }
  end

  def app = Wurk::API::App.new(config: config)

  def config
    @config ||= build_config
  end

  def build_config
    Wurk::Configuration.new.tap do |cfg|
      cfg.api_token(ADMIN_TOKEN, scopes: %i[admin])
      cfg.api_token(ENQUEUE_TOKEN, scopes: %i[enqueue])
      cfg.api_enqueue_classes = [@class_name]
      yield cfg if block_given?
    end
  end

  def queued_payloads
    @pool.with { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }
  end

  def call(method, path, token: ADMIN_TOKEN, body: '', inherited: false)
    env = {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => '',
      'QUERY_STRING' => '',
      'CONTENT_TYPE' => 'application/json',
      'CONTENT_LENGTH' => body.bytesize.to_s,
      'rack.input' => StringIO.new(body),
      'rack.errors' => StringIO.new
    }
    env['HTTP_AUTHORIZATION'] = "Bearer #{token}" if token
    env[Wurk::API::READ_ONLY_ENV] = true if inherited
    status, headers, raw = app.call(env)
    [status, headers, raw.empty? ? {} : JSON.parse(raw.join)]
  end

  # ENV is process-global; the suite-wide mutex is the same one every other
  # global-state test takes.
  def with_env(name, value)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      previous = ENV.fetch(name, nil)
      ENV[name] = value
      begin
        yield
      ensure
        ENV[name] = previous
      end
    end
  end
end
