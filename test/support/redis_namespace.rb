# frozen_string_literal: true

# Per-test Redis namespace isolation. Required for parallel test safety.
# Each test gets a unique key prefix keyed to PID + object_id, and the
# namespace is wiped in teardown. See docs/idea/11-testing-ci.md.
module RedisNamespace
  def setup
    super
    @wurk_test_namespace = "wurktest:#{Process.pid}:#{object_id}:"
    # TODO: scope Wurk.redis to use this prefix during the test
  end

  def teardown
    # TODO: SCAN + DEL all keys under @wurk_test_namespace
    super
  end
end
