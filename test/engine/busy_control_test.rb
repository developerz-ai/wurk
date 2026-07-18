# frozen_string_literal: true

require_relative '../engine_test_helper'

# Drives the Busy-page process-control endpoints (issue #101, spec §25.4
# POST /busy): quiet (SIGTSTP) and stop (SIGTERM) for one process by identity
# or every live process. Asserts the signal lands on the process's
# `<identity>-signals` LIST (the same channel the heartbeat drains).
class BusyControlTest < Wurk::Test::EngineCase
  parallelize_me!

  def setup
    super
    # SameOriginGuard 403s unsafe methods lacking this header; a same-origin SPA
    # fetch always sends it, so default it for every mutation in this suite.
    header 'Sec-Fetch-Site', 'same-origin'
    @ns = "wurkbusy:#{::Process.pid}:#{object_id.to_s(16)}"
    @identity = "host-#{@ns}:1234:abcd"
  end

  def teardown
    ::Wurk.redis do |c|
      c.call('SREM', ::Wurk::Keys::PROCESSES, @identity, "#{@identity}-emb")
      c.call('DEL', @identity, "#{@identity}-signals", "#{@identity}-emb", "#{@identity}-emb-signals")
    end
  ensure
    super
  end

  def test_quiet_pushes_tstp_to_the_process_signal_list
    seed_process(@identity)
    post '/wurk/api/busy/quiet', { identity: @identity }

    assert_ok
    assert_equal 1, json_body[:count]
    assert_equal 'TSTP', last_signal(@identity)
  end

  def test_stop_pushes_term_to_the_process_signal_list
    seed_process(@identity)
    post '/wurk/api/busy/stop', { identity: @identity }

    assert_ok
    assert_equal 1, json_body[:count]
    assert_equal 'TERM', last_signal(@identity)
  end

  def test_unknown_identity_is_404
    post '/wurk/api/busy/stop', { identity: 'no-such-process' }

    assert_equal 404, last_response.status
  end

  def test_quiet_all_signals_every_non_embedded_process
    seed_process(@identity)
    emb = "#{@identity}-emb"
    seed_process(emb, embedded: true)

    post '/wurk/api/busy/quiet', { identity: 'all' }

    assert_ok
    assert_operator json_body[:count], :>=, 1
    assert_equal 'TSTP', last_signal(@identity)
    # Embedded processes are skipped — no separate process to signal.
    assert_nil last_signal(emb)
  end

  def test_embedded_single_process_is_a_noop
    emb = "#{@identity}-emb"
    seed_process(emb, embedded: true)

    post '/wurk/api/busy/stop', { identity: emb }

    assert_ok
    assert_equal 0, json_body[:count]
    assert_nil last_signal(emb)
  end

  private

  def json_body = ::JSON.parse(last_response.body, symbolize_names: true)

  def assert_ok
    assert_equal 200, last_response.status, "non-200 response: body=#{last_response.body[0, 500]}"
  end

  def seed_process(identity, embedded: false)
    info = {
      'hostname' => 'testhost', 'pid' => 1234, 'tag' => @ns,
      'concurrency' => 5, 'queues' => ['default'],
      'identity' => identity, 'version' => ::Wurk::VERSION, 'embedded' => embedded
    }
    ::Wurk.redis do |c|
      c.call('SADD', ::Wurk::Keys::PROCESSES, identity)
      c.call('HSET', identity, 'info', ::Wurk.dump_json(info),
             'busy', '0', 'beat', ::Time.now.to_f.to_s, 'quiet', 'false',
             'rss', '1000', 'rtt_us', '10', 'concurrency', '5')
    end
  end

  def last_signal(identity)
    ::Wurk.redis { |c| c.call('LINDEX', "#{identity}-signals", 0) }
  end
end
