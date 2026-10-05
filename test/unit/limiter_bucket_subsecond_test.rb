# frozen_string_literal: true

require_relative '../test_helper'

# The bucket's sleep-to-boundary must keep sub-second precision. Computing the
# distance from TIME's whole seconds made a :second bucket sleep a full 1.0s
# even with the boundary 0.1s away, overshooting by up to ~1s and eating the
# caller's wait_timeout. limiter_bucket_test.rb's F9 range (0.051..1.0) cannot
# tell the two apart, so this arranges a boundary a fraction of a second out.
class LimiterBucketSubsecondTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @name = "bss-#{Process.pid}-#{object_id}"
    @pool = Wurk::RedisPool.new(size: 2, url: Wurk::Test.redis_url, timeout: 2, name: 'bss')
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
    Wurk::Limiter.reset_config!
    Wurk::Limiter.config.redis = @pool
  end

  def teardown
    @pool.disconnect!
    Wurk::Limiter.reset_config!
  ensure
    super
  end

  def test_sleep_targets_a_sub_second_boundary
    lim = Wurk::Limiter.bucket(@name, 1, :second, wait_timeout: 3)
    slept = []
    lim.define_singleton_method(:sleep) do |secs|
      slept << secs
      Kernel.sleep(secs)
    end
    exhausted_in = redis_second_late_in_its_tail
    lim.within_limit {} # exhausts a second whose boundary is ~0.15-0.3s out
    ran = false
    lim.within_limit { ran = true }

    assert ran
    if slept.empty?
      # A stalled box can cross the boundary before the second call; it must
      # then have acquired in a later second, not inside the exhausted one.
      assert_operator redis_time.first, :>, exhausted_in
    else
      assert_operator slept.first, :<, 0.5, "first sleep #{slept.first}s overshoots a boundary <0.3s away"
    end
  end

  private

  def redis_time = @pool.with { |c| c.call('TIME').map(&:to_i) }

  # Polls the Redis clock (the limiter's clock) until it sits 0.7-0.85s into
  # a second, and returns that second.
  def redis_second_late_in_its_tail
    loop do
      secs, usecs = redis_time
      return secs if usecs.between?(700_000, 850_000)

      Kernel.sleep(0.01)
    end
  end
end
