# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::Metrics::Deaths against real Redis: the field a payload is counted
# under, the cap on distinct fields, and the read side's folding.
class MetricsDeathsTest < Wurk::Test::UnitCase
  parallelize_me!

  Deaths = Wurk::Metrics::Deaths

  def setup
    super
    @pool = Wurk.configuration.redis_pool
  end

  def teardown
    @pool.with { |c| c.call('UNLINK', Wurk::Keys::STAT_DEATHS) }
  ensure
    super
  end

  def test_field_names_the_queue_and_the_wrapped_class_never_the_jid
    assert_equal '["q","Real"]', Deaths.field('{"queue":"q","class":"Wrapper","wrapped":"Real","jid":"j1"}')
    assert_equal '["q","Plain"]', Deaths.field('queue' => 'q', 'class' => 'Plain')
    assert_equal '["unknown","unknown"]', Deaths.field('not json {')
    assert_equal '["unknown","unknown"]', Deaths.field('[1]')
    assert_equal '["unknown","unknown"]', Deaths.field('{"queue":7,"class":""}')
    assert_equal '["q","A\\/B"]', Deaths.field('queue' => 'q', 'class' => 'A/B'), 'escaped as cjson does'
  end

  # The promote script writes its field with cjson: whatever json version is
  # installed, Ruby must write the same bytes.
  def test_field_is_the_bytes_redis_cjson_writes
    ['A/B', '</script>', "L\u2028S", 'Plain::Job', 'q"uote', 'back\\slash'].each do |klass|
      cjson = @pool.with { |c| c.call('EVAL', 'return cjson.encode({ARGV[1], ARGV[2]})', 0, 'q', klass) }

      assert_equal cjson.dup.force_encoding(Encoding::UTF_8), Deaths.field('queue' => 'q', 'class' => klass), klass
    end
  end

  def test_new_fields_past_the_cap_fold_into_overflow
    stub_const(:MAX_SERIES, 2) do
      @pool.with do |c|
        %w[A B C A D].each { |klass| Deaths.record(c, Wurk.dump_json('queue' => 'q', 'class' => klass)) }
      end
    end

    assert_equal [[{ 'queue' => 'other', 'class' => 'other' }, 2], [{ 'queue' => 'q', 'class' => 'A' }, 2],
                  [{ 'queue' => 'q', 'class' => 'B' }, 1]], read
  end

  # A reply lost after the increment landed must not fail the kill (the job is
  # already in the dead set, and a raise would have the caller kill it again)
  # nor be retried into a second count.
  def test_a_lost_reply_is_reported_never_retried_or_raised
    reports = []
    config = Wurk::Configuration.new
    config.error_handlers.replace([->(error, context, _config) { reports << [error.class, context[:context]] }])
    @pool.with do |real|
      Deaths.record(LostReply.new(real), Wurk.dump_json('queue' => 'q', 'class' => 'A'), config: config)
    end

    assert_equal [[{ 'queue' => 'q', 'class' => 'A' }, 1]], read
    assert_equal [[RedisClient::ConnectionError, 'dead-set death counter']], reports
  end

  # Runs each one-shot command for real, then drops its reply.
  class LostReply
    def initialize(conn)
      @conn = conn
    end

    def call(*) = @conn.call(*)

    def call_once(*)
      @conn.call_once(*)
      raise RedisClient::ConnectionError, 'reply lost'
    end
  end

  def test_samples_read_resp2_and_resp3_and_sum_fields_with_the_same_labels
    resp3 = { '["q","A\\/B"]' => '2', '["q","A/B"]' => '3', 'junk' => '1' }
    expected = [[{ 'queue' => 'q', 'class' => 'A/B' }, 5], [{ 'queue' => 'unknown', 'class' => 'unknown' }, 1]]

    assert_equal expected, Deaths.samples(resp3)
    assert_equal expected, Deaths.samples(resp3.to_a.flatten)
    assert_empty Deaths.samples(nil)
  end

  private

  def read
    Deaths.samples(@pool.with { |c| c.call('HGETALL', Wurk::Keys::STAT_DEATHS) })
  end

  def stub_const(name, value)
    saved = Deaths.const_get(name)
    Deaths.send(:remove_const, name)
    Deaths.const_set(name, value)
    yield
  ensure
    Deaths.send(:remove_const, name)
    Deaths.const_set(name, saved)
  end
end
