# frozen_string_literal: true

# Per-test Redis isolation. Each minitest-parallel_fork worker runs against its
# own Redis logical DB (assigned in test_helper's after_parallel_fork hook), so
# concurrent test *classes* never see each other's keys. Within a worker, classes
# run sequentially, so wiping the worker's DB after every test gives each test a
# clean slate without affecting any other worker. Workers never touch DB 0.
module RedisNamespace
  def teardown
    Wurk.redis { |conn| conn.call('FLUSHDB') }
  rescue StandardError
    # A test may have torn down or swapped the global pool; isolation for the
    # *next* test is still covered by the worker-start flush + its own teardown.
    nil
  ensure
    super
  end
end
