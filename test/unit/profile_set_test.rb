# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::ProfileSet / ProfileRecord — the read-side data API over stored
# profiles. Real Redis; each test seeds via Wurk::Profiler.store.
class ProfileSetTest < Wurk::Test::UnitCase
  parallelize_me!

  GECKO = '{"meta":1,"threads":[]}'

  def teardown
    Wurk.redis do |c|
      c.call('DEL', Wurk::Keys::PROFILES)
      keys = c.call('KEYS', '*-*')
      c.call('DEL', *keys) unless keys.empty?
    end
  ensure
    super
  end

  def seed(jid:, token:, type: 'HardJob', elapsed: 0.005, at: ::Time.now)
    Wurk::Profiler.store(jid: jid, type: type, token: token, gecko_json: GECKO,
                         started_at: at, elapsed: elapsed)
  end

  def test_enumerates_stored_profiles
    seed(jid: 'a', token: 't1')
    seed(jid: 'b', token: 't2')

    assert_equal 2, Wurk::ProfileSet.new.size
    assert_equal %w[t1-a t2-b].sort, Wurk::ProfileSet.new.map(&:key).sort
  end

  def test_record_exposes_metadata_and_lazy_data
    seed(jid: 'a', token: 't1', type: 'wall', elapsed: 0.099, at: ::Time.at(1_700_000_000))
    rec = Wurk::ProfileSet.new.first

    assert_equal 'a', rec.jid
    assert_equal 'wall', rec.type
    assert_equal 't1', rec.token
    assert_kind_of Float, rec.elapsed
    assert_in_delta 0.099, rec.elapsed
    assert_operator rec.size, :>, 0
    assert_equal ::Time.at(1_700_000_000), rec.started_at
    assert_equal 't1-a', rec.key
    assert_equal GECKO, Wurk::Profiler.gunzip(rec.data)
  end

  # ZREMRANGEBYSCORE on construction drops members whose expiry already passed.
  def test_purges_expired_members
    seed(jid: 'live', token: 'tlive')
    # An entry whose expiry score is in the past.
    Wurk.redis do |c|
      c.call('HSET', 'told-dead', 'jid', 'dead', 'type', 'x', 'token', 'told',
             'started_at', 1, 'elapsed', 1, 'size', 1, 'sid', '', 'data', 'x')
      c.call('ZADD', Wurk::Keys::PROFILES, ::Time.now.to_i - 60, 'told-dead')
    end

    keys = Wurk::ProfileSet.new.map(&:key)

    assert_includes keys, 'tlive-live'
    refute_includes keys, 'told-dead'
    assert_equal(1, Wurk.redis { |c| c.call('ZCARD', Wurk::Keys::PROFILES) })
  end

  # Upstream lists newest first (ZRANGE … BYSCORE REV on the expiry score).
  def test_enumerates_newest_first
    seed(jid: 'old', token: 't1')
    seed(jid: 'new', token: 't2')
    Wurk.redis { |c| c.call('ZADD', Wurk::Keys::PROFILES, ::Time.now.to_f + 10, 't1-old') }
    Wurk.redis { |c| c.call('ZADD', Wurk::Keys::PROFILES, ::Time.now.to_f + 20, 't2-new') }

    assert_equal %w[t2-new t1-old], Wurk::ProfileSet.new.map(&:key)
  end

  # A profile Sidekiq 8.1's Profiler wrote (its exact HSET field set,
  # `filename` and `sid` included) reads back with upstream's types.
  def test_reads_a_sidekiq_written_record
    Wurk.redis do |c|
      c.call('HSET', 'tok-jid9', 'started_at', 1_700_000_000, 'token', 'tok', 'type', 'HardJob', 'jid', 'jid9',
             'filename', '/tmp/x.json.gz', 'elapsed', '1.25', 'data', 'gz', 'size', 2, 'sid', 'store-id')
      c.call('ZADD', Wurk::Keys::PROFILES, ::Time.now.to_f + 60, 'tok-jid9')
    end

    rec = Wurk::ProfileSet.new.first

    assert_equal ['jid9', 'HardJob', 'tok', 2, 1.25, ::Time.at(1_700_000_000)],
                 [rec.jid, rec.type, rec.token, rec.size, rec.elapsed, rec.started_at]
  end

  def test_each_returns_enumerator_without_block
    seed(jid: 'a', token: 't1')

    assert_kind_of Enumerator, Wurk::ProfileSet.new.each
  end
end
