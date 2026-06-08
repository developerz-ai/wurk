# frozen_string_literal: true

require_relative '../engine_test_helper'

# Drives the Profiles endpoints (#162) against the booted dummy app via
# Rack::Test: the JSON list (/api/profiles) and the raw gzipped blob
# (/profiles/:key/data). The external upload path (/profiles/:key) hits the
# Firefox profiler over the network, so it's not exercised here.
class ProfilesEndpointsTest < Wurk::Test::EngineCase
  parallelize_me!

  GECKO = '{"meta":{"interval":1},"threads":[]}'

  def teardown
    ::Wurk.redis do |c|
      c.call('DEL', ::Wurk::Keys::PROFILES)
      keys = c.call('KEYS', '*-*')
      c.call('DEL', *keys) unless keys.empty?
    end
  ensure
    super
  end

  def seed(jid:, token:, type: 'vernier', elapsed_ms: 7)
    ::Wurk::Profiler.store(jid: jid, type: type, gecko_json: GECKO,
                           started_at: ::Time.now, elapsed_ms: elapsed_ms, token: token)
  end

  def test_api_profiles_lists_records
    seed(jid: 'a', token: 't1', type: 'wall', elapsed_ms: 12)

    get '/wurk/api/profiles'

    assert_ok
    row = json_body.first

    assert_equal 't1-a', row[:key]
    assert_equal 'a', row[:jid]
    assert_equal 'wall', row[:type]
    assert_equal 12, row[:elapsed]
    assert_operator row[:size], :>, 0
  end

  def test_api_profiles_empty_when_none
    get '/wurk/api/profiles'

    assert_ok
    assert_empty json_body
  end

  def test_profile_data_streams_gzipped_blob
    key = seed(jid: 'b', token: 't2')

    get "/wurk/profiles/#{key}/data"

    assert_equal 200, last_response.status
    assert_equal 'gzip', last_response.headers['Content-Encoding']
    assert_equal GECKO, ::Wurk::Profiler.gunzip(last_response.body)
  end

  def test_profile_data_404_for_unknown_key
    get '/wurk/profiles/nope-missing/data'

    assert_equal 404, last_response.status
  end

  private

  def json_body
    ::JSON.parse(last_response.body, symbolize_names: true)
  end

  def assert_ok
    assert_equal 200, last_response.status, "non-200 response: body=#{last_response.body[0, 500]}"
  end
end
