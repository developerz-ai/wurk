# frozen_string_literal: true

# Fails the test that leaves a Wurk background thread running.
#
# A leaked `scheduler` poller keeps promoting due retry/schedule entries in the
# worker's Redis DB long after the test that started it has finished, and the
# next class on that worker finds its fixtures gone (#522: WebSearchTest,
# WebExtensionsTest, ApiMutationsTest all went red for this, with no change of
# their own). Blaming the victim's fixtures cannot end that class; failing the
# leaker can.
#
# Matched by the names lib gives its threads (`Component#safe_thread` and the
# explicit `Thread#name=` sites), never by "every new thread": tests start
# plain helper threads of their own, and those are not this guard's business.
# A leaker is killed after it is reported, so one leak fails one test instead
# of every test after it.
module ThreadLeakGuard
  NAMES = %w[
    scheduler cron-poller heartbeat boot-reclaim launcher-stop history-snapshot
    metrics-flush metrics-rollup queue-metrics watchdog
    wurk-leader wurk-reaper wurk-health wurk-health-retry
    wurk-reliable_push-drainer wurk-orphan-watchdog
  ].freeze
  PROCESSOR = %r{/processor\z}

  # A stop that has been asked for may still be unwinding its last tick; give
  # it this long before calling it a leak.
  GRACE = 2.0
  POLL = 0.02

  def self.wurk_threads
    ::Thread.list.select do |t|
      next false if t == ::Thread.current || !t.alive?

      name = t.name.to_s
      NAMES.include?(name) || PROCESSOR.match?(name)
    end
  end

  def before_setup
    @thread_leak_baseline = ThreadLeakGuard.wurk_threads
    super
  end

  def after_teardown
    super
  ensure
    check_for_leaked_wurk_threads
  end

  private

  def check_for_leaked_wurk_threads
    baseline = @thread_leak_baseline || []
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + GRACE
    leaked = ThreadLeakGuard.wurk_threads - baseline
    while leaked.any? && ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) < deadline
      sleep POLL
      leaked = ThreadLeakGuard.wurk_threads - baseline
    end
    return if leaked.empty?

    names = leaked.map(&:name)
    leaked.each(&:kill)
    leaked.each { |t| t.join(1) }

    flunk "#{self.class}##{name} leaked Wurk background thread(s) #{names.inspect}; " \
          'stop every launcher/poller/component the test starts (ensure or teardown)'
  end
end

Minitest::Test.prepend(ThreadLeakGuard)
