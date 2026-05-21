# frozen_string_literal: true

require_relative '../test_helper'

class LuaTest < Wurk::Test::UnitCase
  parallelize_me!

  REDIS_URL = ENV['REDIS_URL'] || 'redis://localhost:6379/0'

  def setup
    super
    @pool = Wurk::RedisPool.new(size: 1, url: REDIS_URL, timeout: 2, name: 'lua-test')
    @ns   = "luatest:#{Process.pid}:#{object_id}"
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
  end

  def teardown
    @pool.with do |c|
      cursor = '0'
      loop do
        cursor, keys = c.call('SCAN', cursor, 'MATCH', "#{@ns}:*", 'COUNT', 500)
        c.call('DEL', *keys) unless keys.empty?
        break if cursor == '0'
      end
    end
    @pool.disconnect!
  ensure
    super
  end

  # --- registry shape ------------------------------------------------

  def test_scripts_registry_holds_expected_keys
    assert_equal(
      %i[zpopbyscore bulk_push reliable_schedule_promote
         batch_push batch_complete batch_invalidate].sort,
      Wurk::Lua::SCRIPTS.keys.sort
    )
  end

  def test_scripts_registry_is_frozen
    assert_predicate Wurk::Lua::SCRIPTS, :frozen?, 'SCRIPTS must be frozen to prevent mutation'
  end

  def test_every_script_source_is_a_non_empty_string
    Wurk::Lua::SCRIPTS.each do |name, src|
      assert_kind_of String, src, "#{name} source must be a String"
      refute_empty src, "#{name} source must not be empty"
    end
  end

  def test_shas_match_sha1_of_each_source
    Wurk::Lua::SCRIPTS.each do |name, src|
      expected = Digest::SHA1.hexdigest(src)

      assert_equal expected, Wurk::Lua::SHAS[name],
                   "#{name} SHA must equal SHA1(source)"
    end
  end

  def test_shas_is_frozen
    assert_predicate Wurk::Lua::SHAS, :frozen?, 'SHAS must be frozen'
  end

  # --- zpopbyscore: verbatim from sidekiq-free.md §1.8 ---------------
  #
  # Wire-compat sanity check. Any whitespace edit changes the SHA and
  # forces all production processes to re-upload on first call. The exact
  # bytes below come from docs/target/sidekiq-free.md §1.8.

  def test_zpopbyscore_matches_spec_verbatim
    expected = <<~LUA
      local key, now = KEYS[1], ARGV[1]
      local jobs = redis.call("zrange", key, "-inf", now, "byscore", "limit", 0, 1)
      if jobs[1] then
        redis.call("zrem", key, jobs[1])
        return jobs[1]
      end
    LUA

    assert_equal expected, Wurk::Lua::ZPOPBYSCORE
  end

  # --- execution against real Redis ---------------------------------

  def test_zpopbyscore_pops_oldest_due_job
    set_key = "#{@ns}:retry"
    @pool.with do |c|
      c.call('ZADD', set_key, 100, 'jobA', 200, 'jobB', 300, 'jobC')
      result = Wurk::Lua::Loader.eval_cached(c, :zpopbyscore, keys: [set_key], argv: [250])

      assert_equal 'jobA', result
      assert_equal 2, c.call('ZCARD', set_key)
    end
  end

  def test_zpopbyscore_returns_nil_when_no_jobs_due
    set_key = "#{@ns}:retry"
    @pool.with do |c|
      c.call('ZADD', set_key, 1000, 'jobFuture')
      result = Wurk::Lua::Loader.eval_cached(c, :zpopbyscore, keys: [set_key], argv: [500])

      assert_nil result
      assert_equal 1, c.call('ZCARD', set_key)
    end
  end

  def test_bulk_push_lpushes_all_jobs_and_registers_queue
    qname = "#{@ns}:q"
    list  = "queue:#{qname}"
    qset  = "#{@ns}:queues"
    @pool.with do |c|
      count = Wurk::Lua::Loader.eval_cached(
        c, :bulk_push, keys: [list, qset], argv: [qname, '{"jid":"1"}', '{"jid":"2"}', '{"jid":"3"}']
      )

      assert_equal 3, count
      assert_equal 3, c.call('LLEN', list)
      assert_equal 1, c.call('SISMEMBER', qset, qname)
      c.call('DEL', list, qset)
    end
  end

  # rubocop:disable Minitest/MultipleAssertions
  def test_reliable_schedule_promote_moves_due_jobs_to_their_queues
    sset = "#{@ns}:schedule"
    qset = "#{@ns}:queues"
    @pool.with do |c|
      c.call('ZADD', sset, 100, '{"queue":"alpha","jid":"a"}', 150, '{"queue":"beta","jid":"b"}',
             900, '{"queue":"alpha","jid":"future"}')
      count = Wurk::Lua::Loader.eval_cached(
        c, :reliable_schedule_promote, keys: [sset, qset], argv: [500, "#{@ns}:queue:"]
      )

      assert_equal 2, count
      assert_equal 1, c.call('LLEN', "#{@ns}:queue:alpha")
      assert_equal 1, c.call('LLEN', "#{@ns}:queue:beta")
      assert_equal 1, c.call('ZCARD', sset)
      assert_equal 2, c.call('SCARD', qset)
      c.call('DEL', "#{@ns}:queue:alpha", "#{@ns}:queue:beta")
    end
  end

  def test_batch_push_increments_counters_jids_and_queue
    bkey  = "#{@ns}:b-x"
    jids  = "#{@ns}:b-x-jids"
    list  = "#{@ns}:queue:default"
    qset  = "#{@ns}:queues"
    @pool.with do |c|
      Wurk::Lua::Loader.eval_cached(
        c, :batch_push, keys: [bkey, jids, list, qset], argv: ['default', 'JID1', '{"jid":"JID1"}']
      )

      assert_equal '1', c.call('HGET', bkey, 'total')
      assert_equal '1', c.call('HGET', bkey, 'pending')
      assert_equal 1, c.call('SISMEMBER', jids, 'JID1')
      assert_equal 1, c.call('LLEN', list)
      assert_equal 1, c.call('SISMEMBER', qset, 'default')
      c.call('DEL', list)
    end
  end

  def test_batch_complete_decrements_pending_only_for_known_jid
    bkey = "#{@ns}:b-y"
    jids = "#{@ns}:b-y-jids"
    @pool.with do |c|
      c.call('HSET', bkey, 'total', 2, 'pending', 2)
      c.call('SADD', jids, 'A', 'B')

      remaining = Wurk::Lua::Loader.eval_cached(c, :batch_complete, keys: [bkey, jids], argv: ['A'])

      assert_equal 1, remaining
      assert_equal '1', c.call('HGET', bkey, 'pending')

      unknown = Wurk::Lua::Loader.eval_cached(c, :batch_complete, keys: [bkey, jids], argv: ['ZZZ'])

      assert_equal(-1, unknown)
      assert_equal '1', c.call('HGET', bkey, 'pending')
    end
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_batch_invalidate_clears_jids_and_flags_hash
    bkey = "#{@ns}:b-z"
    jids = "#{@ns}:b-z-jids"
    @pool.with do |c|
      c.call('HSET', bkey, 'total', 3, 'pending', 3)
      c.call('SADD', jids, 'A', 'B', 'C')

      Wurk::Lua::Loader.eval_cached(c, :batch_invalidate, keys: [bkey, jids], argv: [])

      assert_equal 0, c.call('EXISTS', jids)
      assert_equal '1', c.call('HGET', bkey, 'invalidated')
    end
  end
end
