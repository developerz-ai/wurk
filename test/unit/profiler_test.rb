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
    key = Wurk::Profiler.store(jid: 'j1', type: 'HardJob', token: 'tok', gecko_json: GECKO,
                               started_at: ::Time.at(1_700_000_000), elapsed: 0.042)

    assert_equal 'tok-j1', key
    Wurk.redis do |c|
      assert_equal 1, c.call('ZSCORE', Wurk::Keys::PROFILES, key) ? 1 : 0
      assert_equal 'j1', c.call('HGET', key, 'jid')
      assert_equal 'HardJob', c.call('HGET', key, 'type')
      assert_equal '1700000000', c.call('HGET', key, 'started_at')
      assert_in_delta 0.042, Float(c.call('HGET', key, 'elapsed'))
      assert_equal GECKO, Wurk::Profiler.gunzip(c.call('HGET', key, 'data'))
      assert_operator c.call('TTL', key).to_i, :>, 0
    end
  end

  # Upstream's HSET field set, minus its tmp `filename`. `sid` stays unset:
  # it is the profile-store id the Web UI caches, and a value in it makes
  # Sidekiq's UI redirect without uploading.
  def test_store_writes_upstream_fields_and_no_sid
    key = Wurk::Profiler.store(jid: 'j6', type: 'HardJob', token: 'tok', gecko_json: GECKO,
                               started_at: ::Time.now, elapsed: 1.5)

    fields = Wurk.redis { |c| c.call('HKEYS', key) }

    assert_equal %w[data elapsed jid size started_at token type], fields.sort
    assert_equal(Wurk::Profiler::EXPIRY, Wurk.redis { |c| c.call('TTL', key) })
  end

  # ProfileRecord round-trip: what store writes reads back with upstream's
  # types — Float seconds, Integer size, Time started_at.
  def test_store_round_trips_through_profile_record
    Wurk::Profiler.store(jid: 'j7', type: 'HardJob', token: 'tok', gecko_json: GECKO,
                         started_at: ::Time.at(1_700_000_123), elapsed: 2.25)

    rec = Wurk::ProfileSet.new.find { |r| r.jid == 'j7' }

    assert_equal ['tok', 'HardJob', 2.25, ::Time.at(1_700_000_123), 'tok-j7'],
                 [rec.token, rec.type, rec.elapsed, rec.started_at, rec.key]
    assert_equal GECKO, Wurk::Profiler.gunzip(rec.data)
  end

  # The capture path stores token = the job's `profile` value and type = the
  # (wrapped) job class, as Sidekiq::Profiler#call does.
  def test_capture_stores_token_from_profile_option_and_type_from_class
    fake = Module.new do
      def self.profile(out:, mode:, **)
        raise 'mode' unless mode == :cpu

        result = yield
        File.write(out, '{"threads":[]}')
        result
      end
    end
    stub_const_vernier(fake) do
      job = { 'jid' => 'j8', 'class' => 'Wrapper', 'wrapped' => 'RealJob', 'profile' => 'slowpoke',
              'profiler_options' => { 'mode' => 'cpu' } }

      assert_equal :ran, Wurk::Profiler.call(job) { :ran }
    end

    rec = Wurk::ProfileSet.new.find { |r| r.jid == 'j8' }

    assert_equal %w[slowpoke RealJob slowpoke-j8], [rec.token, rec.type, rec.key]
    assert_kind_of Float, rec.elapsed
  end

  # Forked workers persist through their own capsule pool, so `store` accepts an
  # explicit `pool:` — exercise that path (not just the default `Wurk.redis`).
  def test_store_writes_through_an_explicit_pool
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url)
    key = Wurk::Profiler.store(jid: 'jp', type: 'HardJob', token: 'tp', gecko_json: GECKO,
                               started_at: ::Time.at(1_700_000_000), elapsed: 0.007, pool: pool)

    assert_equal 'tp-jp', key
    Wurk.redis do |c|
      assert_equal 'jp', c.call('HGET', key, 'jid')
      assert_operator c.call('ZSCORE', Wurk::Keys::PROFILES, key).to_i, :>, 0
    end
  ensure
    pool&.disconnect!
  end

  def test_store_score_is_future_expiry
    key = Wurk::Profiler.store(jid: 'j2', type: 'HardJob', token: 't2', gecko_json: GECKO,
                               started_at: ::Time.now, elapsed: 0.001)
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

  private

  def stub_const_vernier(mod)
    skip 'real vernier loaded' if defined?(::Vernier)

    Object.const_set(:Vernier, mod)
    begin
      yield
    ensure
      Object.send(:remove_const, :Vernier)
    end
  end
end
