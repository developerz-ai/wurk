# frozen_string_literal: true

require_relative '../engine_test_helper'

# Drives the Profiles endpoints (#162) against the booted dummy app via
# Rack::Test: the JSON list (/api/profiles) and the raw gzipped blob
# (/profiles/:key/data). The external upload path (/profiles/:key) is driven
# with Net::HTTP.start stubbed, never the real Firefox profiler.
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

  def seed(jid:, token:, type: 'HardJob', elapsed: 0.007)
    ::Wurk::Profiler.store(jid: jid, type: type, token: token, gecko_json: GECKO,
                           started_at: ::Time.now, elapsed: elapsed)
  end

  def test_api_profiles_lists_records
    seed(jid: 'a', token: 't1', type: 'wall', elapsed: 0.012)

    get '/wurk/api/profiles'

    assert_ok
    row = json_body.first

    assert_equal 't1-a', row[:key]
    assert_equal 'a', row[:jid]
    assert_equal 'wall', row[:type]
    assert_in_delta 0.012, row[:elapsed]
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

  # The store answers with a JWT; the view URL takes its payload's
  # `profileToken`, never the raw body (upstream Web::Application).
  def test_profile_show_uploads_once_and_redirects_to_the_profile_token
    key = seed(jid: 'c', token: 't3')
    calls = 0
    fake = lambda do |*_args, **_opts|
      calls += 1
      store_response
    end

    stub_http_start(fake) do
      get "/wurk/profiles/#{key}"
      get "/wurk/profiles/#{key}"
    end

    assert_equal 302, last_response.status
    assert_equal 'https://profiler.firefox.com/public/abc123', last_response.headers['Location']
    assert_equal 1, calls
    assert_equal('abc123', ::Wurk.redis { |c| c.call('HGET', key, 'sid') })
  end

  # A `sid` Sidekiq's Web UI cached is reused as-is.
  def test_profile_show_reuses_a_cached_sid
    key = seed(jid: 'd', token: 't4')
    ::Wurk.redis { |c| c.call('HSET', key, 'sid', 'fromsidekiq') }

    stub_http_start(->(*) { flunk 'uploaded despite a cached sid' }) { get "/wurk/profiles/#{key}" }

    assert_equal 'https://profiler.firefox.com/public/fromsidekiq', last_response.headers['Location']
  end

  def test_profile_show_404_for_unknown_key
    get '/wurk/profiles/nope-missing'

    assert_equal 404, last_response.status
  end

  private

  def stub_http_start(fake)
    original = ::Net::HTTP.method(:start)
    ::Net::HTTP.singleton_class.send(:define_method, :start) { |*args, **opts| fake.call(*args, **opts) }
    yield
  ensure
    ::Net::HTTP.singleton_class.send(:define_method, :start, original)
  end

  def store_response
    payload = ['{"profileToken":"abc123"}'].pack('m0').delete('=').tr('+/', '-_')
    res = ::Net::HTTPOK.new('1.1', '200', 'OK')
    res.instance_variable_set(:@body, "eyJhbGciOiJIUzI1NiJ9.#{payload}.sig\n")
    res.instance_variable_set(:@read, true)
    res
  end

  def json_body
    ::JSON.parse(last_response.body, symbolize_names: true)
  end

  def assert_ok
    assert_equal 200, last_response.status, "non-200 response: body=#{last_response.body[0, 500]}"
  end
end
