# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::Profiler storage + (de)compression. The live Vernier capture path is
# only reachable when the `vernier` gem is loaded (an optional dev dependency),
# so these tests exercise `store` directly with a ready gecko-JSON blob — the
# same data the capture path would persist.
class ProfilerTest < Wurk::Test::UnitCase
  parallelize_me!

  GECKO = '{"meta":{"interval":1},"threads":[]}'

  def teardown
    Wurk.redis do |c|
      c.call('DEL', Wurk::Keys::PROFILES)
      keys = c.call('KEYS', '*-*')
      c.call('DEL', *keys) unless keys.empty?
    end
  ensure
    super
  end

  def test_gzip_round_trips
    assert_equal GECKO, Wurk::Profiler.gunzip(Wurk::Profiler.gzip(GECKO))
  end

  def test_store_writes_hash_and_zset_member
    key = Wurk::Profiler.store(jid: 'j1', type: 'vernier', gecko_json: GECKO,
                               started_at: ::Time.at(1_700_000_000), elapsed_ms: 42, token: 'tok')

    assert_equal 'tok-j1', key
    Wurk.redis do |c|
      assert_equal 1, c.call('ZSCORE', Wurk::Keys::PROFILES, key) ? 1 : 0
      assert_equal 'j1', c.call('HGET', key, 'jid')
      assert_equal 'vernier', c.call('HGET', key, 'type')
      assert_equal '1700000000', c.call('HGET', key, 'started_at')
      assert_equal '42', c.call('HGET', key, 'elapsed')
      assert_equal GECKO, Wurk::Profiler.gunzip(c.call('HGET', key, 'data'))
      assert_operator c.call('TTL', key).to_i, :>, 0
    end
  end

  # Forked workers persist through their own capsule pool, so `store` accepts an
  # explicit `pool:` — exercise that path (not just the default `Wurk.redis`).
  def test_store_writes_through_an_explicit_pool
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url)
    key = Wurk::Profiler.store(jid: 'jp', type: 'vernier', gecko_json: GECKO,
                               started_at: ::Time.at(1_700_000_000), elapsed_ms: 7, token: 'tp', pool: pool)

    assert_equal 'tp-jp', key
    Wurk.redis do |c|
      assert_equal 'jp', c.call('HGET', key, 'jid')
      assert_operator c.call('ZSCORE', Wurk::Keys::PROFILES, key).to_i, :>, 0
    end
  ensure
    pool&.disconnect!
  end

  def test_store_score_is_future_expiry
    key = Wurk::Profiler.store(jid: 'j2', type: 'vernier', gecko_json: GECKO,
                               started_at: ::Time.now, elapsed_ms: 1, token: 't2')
    score = Wurk.redis { |c| c.call('ZSCORE', Wurk::Keys::PROFILES, key) }.to_i

    assert_operator score, :>, ::Time.now.to_i
  end

  # Capture is a no-op (just runs the block) when the job didn't opt in.
  def test_call_without_profile_option_just_yields
    ran = false
    result = Wurk::Profiler.call({ 'jid' => 'j3' }) do
      ran = true
      :ok
    end

    assert ran
    assert_equal :ok, result
    assert_equal(0, Wurk.redis { |c| c.call('ZCARD', Wurk::Keys::PROFILES) })
  end

  # Every job passes through `call`, so it must not declare a block parameter:
  # `&block` makes MRI reify the dispatch block into a Proc even for the jobs
  # that never profile. `yield` does not.
  def test_call_declares_no_block_parameter
    kinds = Wurk::Profiler.method(:call).parameters.map(&:first)

    refute_includes kinds, :block
  end

  # Regression: the hook must NOT swallow the job's exceptions — a broad rescue
  # here once ate JobRetry::Skip and re-ran the block, scheduling phantom retries.
  def test_call_propagates_job_exceptions
    assert_raises(RuntimeError) do
      Wurk::Profiler.call({ 'jid' => 'j5' }) { raise 'boom' }
    end
  end

  # Opted in but vernier absent → still a no-op run, nothing stored.
  def test_call_with_profile_but_no_vernier_yields_without_capturing
    skip 'vernier is loaded; capture path active' if defined?(::Vernier)

    result = Wurk::Profiler.call({ 'jid' => 'j4', 'profile' => 'slow' }) { :done }

    assert_equal :done, result
    assert_equal(0, Wurk.redis { |c| c.call('ZCARD', Wurk::Keys::PROFILES) })
  end
end
