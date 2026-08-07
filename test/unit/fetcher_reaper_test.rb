# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Drives Wurk::Fetcher::Reaper against real Redis. Each test owns a unique
# public queue + simulated private lists keyed to a dead/alive pid, so
# parallel runs never collide. The periodic thread is never started here —
# tests call the unguarded `reclaim!` for determinism; the locked `reap`
# and the loop lifecycle get their own focused cases.
#
# Spec: docs/target/sidekiq-pro.md §3.2.
class FetcherReaperTest < Wurk::Test::UnitCase
  parallelize_me!

  DEAD_PID = 999_999 # never a running pid in CI/dev

  def setup # rubocop:disable Metrics/AbcSize -- linear fixture wiring, no branching
    super
    @ns           = "reaper-#{Process.pid}-#{object_id}"
    @queue_name   = "#{@ns}-q"
    @public_queue = Wurk::Keys.queue(@queue_name)
    @config       = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @capsule = @config.default_capsule
    @capsule.queues = [@queue_name]
    @pool         = @capsule.redis_pool
    @host         = ENV['DYNO'] || Socket.gethostname
    # Salt every default jid so the global, 72h-TTL PoisonPill counter at
    # `super_fetch:recovered:<jid>` can't accumulate across runs and tip an
    # otherwise-recoverable job over the poison threshold.
    @salt         = SecureRandom.hex(8)
    @lock_key      = "#{Wurk::Fetcher::Reaper::LOCK_KEY}:#{@ns}"
    @full_lock_key = "#{Wurk::Fetcher::Reaper::FULL_LOCK_KEY}:#{@ns}"
    @reaper        = Wurk::Fetcher::Reaper.new(@config, interval: 1, lock_key: @lock_key, full_lock_key: @full_lock_key)
    # Keys created outside @public_queue (full-sweep tests use foreign queues);
    # the whole-keyspace scan would see leftovers from prior tests otherwise.
    @extra_keys    = []
    Wurk::Middleware::PoisonPill.reset!
  end

  def teardown
    Wurk::Middleware::PoisonPill.reset!
    @pool.with do |c|
      keys = c.call('KEYS', "#{@public_queue}*")
      c.call('DEL', *keys) unless keys.empty?
      c.call('DEL', @lock_key, @full_lock_key)
      c.call('DEL', *@extra_keys) unless @extra_keys.empty?
    end
    cleanup_dead_set
    cleanup_recovery_counters
    @config.reset_redis_pools!
  ensure
    super
  end

  # --- orphan reclamation ------------------------------------------------

  def test_reclaims_orphaned_private_list_back_to_public_queue
    seed_private_list(DEAD_PID, %w[a b c])

    reclaimed = @reaper.reclaim!

    assert_equal 3, reclaimed
    assert_equal 0, llen(private_list(DEAD_PID)), 'private list should be drained'
    assert_equal 3, llen(@public_queue), 'jobs should be back on the public queue'
  end

  def test_reclaimed_jobs_land_on_the_public_tail_for_prompt_rerun
    # A job already waiting at the head; reclaimed jobs must sit behind it on
    # the tail (RIGHT) so they are fetched next, matching #bulk_requeue.
    @pool.with { |c| c.call('LPUSH', @public_queue, payload('existing')) }
    seed_private_list(DEAD_PID, %w[recovered])

    @reaper.reclaim!

    # Fetch order is RIGHT (tail); the reclaimed job must be the tail element.
    assert_equal payload('recovered'), lindex(@public_queue, -1)
  end

  def test_does_not_reclaim_a_live_owners_private_list
    seed_private_list(Process.pid, %w[live]) # this very process is alive

    reclaimed = @reaper.reclaim!

    assert_equal 0, reclaimed
    assert_equal 1, llen(private_list(Process.pid)), 'a live owner keeps its in-flight jobs'
    assert_equal 0, llen(@public_queue)
  end

  def test_empty_when_no_private_lists_exist
    assert_equal 0, @reaper.reclaim!
  end

  def test_only_scans_served_queues
    other = Wurk::Keys.queue("#{@ns}-unserved")
    other_priv = "#{other}|#{@host}|#{DEAD_PID}|0"
    @pool.with { |c| c.call('RPUSH', other_priv, payload('x')) }

    reclaimed = @reaper.reclaim!

    assert_equal 0, reclaimed, 'queues this process does not serve are left untouched'
    assert_equal 1, llen(other_priv)
  ensure
    @pool.with { |c| c.call('DEL', other_priv) }
  end

  # --- super_fetch! recovery callback (Pro §3.1) -------------------------

  # A recovery block registered on the reaper's config fires once per orphan
  # reclaimed, with the raw job string and pill=nil (non-poison). This is the
  # end-to-end path: stranded private list → reaper sweep → callback.
  def test_recovery_callback_fires_with_job_string_on_reclaim
    recovered = []
    @config.super_fetch! { |jobstr, pill| recovered << [jobstr, pill] }
    seed_private_list(DEAD_PID, %w[one two])

    @reaper.reclaim!

    assert_equal [payload('one'), payload('two')].sort, recovered.map(&:first).sort
    assert(recovered.all? { |_, pill| pill.nil? }, 'a non-poison recovery passes pill=nil')
  end

  # On the poison path the same block receives a pill responding to
  # .jid/.klass/.count/.queue, so a `pill.jid`-style Pro initializer drops in.
  # rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize
  def test_recovery_callback_receives_pill_on_poison_kill
    jid = SecureRandom.hex(12)
    pill = nil
    @config.super_fetch! { |_jobstr, p| pill = p if p }
    # Two prior recoveries on record; this reclaim is the 3rd → poison.
    Wurk.redis { |c| c.call('SET', recovery_key(jid), '2') }
    @pool.with { |c| c.call('RPUSH', private_list(DEAD_PID), payload('poison', jid: jid)) }

    @reaper.reclaim!

    refute_nil pill, 'a poison kill hands the recovery block a pill'
    assert_equal jid, pill.jid
    assert_equal 'ReaperTestJob', pill.klass
    assert_equal 3, pill.count
    assert_equal @queue_name, pill.queue
  ensure
    Wurk.redis { |c| c.call('DEL', recovery_key(jid)) }
  end
  # rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize

  # --- poison-pill cap ---------------------------------------------------

  # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
  def test_recovery_past_threshold_kills_to_dead_set_instead_of_requeue
    jid = SecureRandom.hex(12)
    job = payload('poison', jid: jid)
    # Two prior recoveries on record; this reclaim is the 3rd → poison.
    Wurk.redis { |c| c.call('SET', recovery_key(jid), '2') }
    @pool.with { |c| c.call('RPUSH', private_list(DEAD_PID), job) }

    reclaimed = @reaper.reclaim!

    assert_equal 1, reclaimed
    assert_equal 0, llen(@public_queue), 'a poison job must not be re-queued'
    assert_equal 0, llen(private_list(DEAD_PID)), 'and must be drained from the private list'
    assert_includes dead_payloads, job, 'poison job belongs in the dead set'
  ensure
    Wurk.redis { |c| c.call('DEL', recovery_key(jid)) }
  end
  # rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions

  def test_under_threshold_recovery_requeues_and_bumps_counter
    jid = SecureRandom.hex(12)
    @pool.with { |c| c.call('RPUSH', private_list(DEAD_PID), payload('ok', jid: jid)) }

    @reaper.reclaim!

    assert_equal 1, llen(@public_queue)
    assert_equal 1, Wurk::Middleware::PoisonPill.recovery_count(jid)
  ensure
    Wurk.redis { |c| c.call('DEL', recovery_key(jid)) }
  end

  # --- liveness: cross-host ----------------------------------------------

  def test_cross_host_owner_with_live_heartbeat_is_skipped
    other_host = 'other-host.example'
    nonce = register_process(other_host, DEAD_PID, info: true)
    seed_private_list(DEAD_PID, %w[remote], host: other_host, nonce: nonce)

    reclaimed = @reaper.reclaim!

    assert_equal 0, reclaimed, 'a beating cross-host owner keeps its jobs'
  ensure
    unregister_process(other_host, DEAD_PID)
  end

  def test_cross_host_owner_without_info_hash_is_reclaimed
    other_host = 'other-host.example'
    nonce = register_process(other_host, DEAD_PID, info: false) # SET member, expired hash
    seed_private_list(DEAD_PID, %w[remote], host: other_host, nonce: nonce)

    reclaimed = @reaper.reclaim!

    assert_equal 1, reclaimed, 'a SET member whose heartbeat lapsed is dead'
  ensure
    unregister_process(other_host, DEAD_PID)
  end

  # A heartbeat under the same host:pid but a *different* incarnation is not
  # this list's owner: that process died, and its successor happens to occupy
  # the pid it used to hold.
  def test_cross_host_owner_with_a_heartbeat_from_another_incarnation_is_reclaimed
    other_host = 'other-host.example'
    register_process(other_host, DEAD_PID, info: true)
    seed_private_list(DEAD_PID, %w[remote], host: other_host, nonce: SecureRandom.hex(6))

    assert_equal 1, @reaper.reclaim!, 'the heartbeat has to match the full identity, not just host:pid'
  ensure
    unregister_process(other_host, DEAD_PID)
  end

  # --- liveness: same host, foreign PID namespace ------------------------

  # F2(a): a container restarting under a fixed hostname comes back in a fresh
  # pid namespace, where the dead owner's pid is likely taken again — here by
  # this very process. Trusting kill(0) on a hostname match alone strands those
  # jobs forever; the incarnation nonce is what tells the two apart.
  def test_same_host_dead_incarnation_is_reclaimed_even_when_its_pid_is_live
    seed_private_list(Process.pid, %w[stranded], nonce: SecureRandom.hex(6))

    assert_equal 1, @reaper.reclaim!, 'a foreign incarnation is not vouched for by a live local pid'
    assert_equal 1, llen(@public_queue)
  end

  # F2(b): two containers share the host's network namespace but not its pid
  # namespace, so the live owner's pid does not exist here. kill(0) would call
  # it dead and drain the list out from under a job that is still running.
  def test_same_host_foreign_incarnation_with_a_live_heartbeat_is_left_alone
    nonce = register_process(@host, unowned_pid, info: true)
    key = seed_private_list(unowned_pid, %w[in-flight], nonce: nonce)

    assert_equal 0, @reaper.reclaim!, 'a beating owner keeps its jobs whatever our pid namespace says'
    assert_equal 1, llen(key)
  ensure
    unregister_process(@host, unowned_pid)
  end

  # The fast path earns its keep: for our own incarnation the OS is
  # authoritative and outranks the heartbeat, so a SIGKILLed sibling is
  # reclaimed the moment the supervisor reaps it instead of 60s later when its
  # `info` hash finally lapses.
  def test_own_incarnation_is_reclaimed_on_a_dead_pid_despite_a_live_heartbeat
    register_process(@host, unowned_pid, info: true, nonce: Wurk::Component::PROCESS_NONCE)
    seed_private_list(unowned_pid, %w[sibling])

    assert_equal 1, @reaper.reclaim!, 'kill(0) decides for our own process tree'
  ensure
    unregister_process(@host, unowned_pid)
  end

  # Our nonce under someone else's host segment: whatever wrote that key, our
  # pid table has no standing to vouch for it, so the heartbeat decides — and
  # with none on record the list is an orphan however live the pid looks here.
  def test_own_nonce_under_a_foreign_host_still_goes_through_the_heartbeat
    seed_private_list(Process.pid, %w[elsewhere], host: 'other-host.example')

    assert_equal 1, @reaper.reclaim!, 'the fast path needs the host to match too, not just the nonce'
  end

  # A pre-nonce key names no incarnation, so the heartbeat is all there is to
  # go on and it can only be matched on the host:pid prefix of an identity.
  def test_pre_nonce_key_with_a_live_heartbeat_is_skipped
    register_process(@host, unowned_pid, info: true)
    key = seed_private_list(unowned_pid, %w[legacy], nonce: nil)

    assert_equal 0, @reaper.reclaim!, 'a beating pre-upgrade owner keeps its jobs'
    assert_equal 1, llen(key)
  ensure
    unregister_process(@host, unowned_pid)
  end

  # --- key parsing -------------------------------------------------------

  def test_ignores_malformed_private_list_keys
    @pool.with do |c|
      c.call('RPUSH', "#{@public_queue}|#{@host}|notapid|0", payload('bad'))
      c.call('RPUSH', "#{@public_queue}|#{@host}|#{DEAD_PID}|notanidx", payload('bad2'))
    end

    assert_equal 0, @reaper.reclaim!, 'non-numeric pid/idx suffixes are not reclaimable'
  end

  # The shape every current process writes. The pre-nonce shape the other
  # cases seed must keep reclaiming too — that is the rolling-upgrade window.
  def test_reclaims_a_nonce_keyed_private_list
    key = "#{@public_queue}|#{@host}|#{DEAD_PID}|#{Wurk::Component::PROCESS_NONCE}|0"
    @pool.with { |c| c.call('RPUSH', key, payload('n1'), payload('n2')) }

    assert_equal 2, @reaper.reclaim!, 'a nonce-keyed orphan is reclaimed'
    assert_equal 0, llen(key), 'private list drained'
  end

  # SecureRandom.hex can emit an all-digit nonce. Read as the pre-nonce shape
  # such a key yields the pid as the host and the nonce as the pid, so its
  # owner's heartbeat is looked up under an identity nobody registered and a
  # *live* owner gets drained out from under itself.
  def test_all_digit_nonce_still_resolves_the_live_owner
    register_process(@host, unowned_pid, info: true, nonce: '123456789012')
    key = seed_private_list(unowned_pid, %w[live], nonce: '123456789012')

    assert_equal 0, @reaper.reclaim!, 'a live owner is never reclaimed'
    assert_equal 1, llen(key), 'in-flight job left alone'
  ensure
    unregister_process(@host, unowned_pid)
  end

  # A bare Docker hostname is 12 hex chars, so ~1 in 175 hosts is all digits.
  # The scoped sweep splits the tail off a known public-queue prefix, so the
  # pre-nonce shape stays unambiguous even then.
  def test_reclaims_a_pre_nonce_private_list_from_an_all_digit_host
    key = "#{@public_queue}|123456789012|#{DEAD_PID}|0"
    @pool.with { |c| c.call('RPUSH', key, payload('legacy')) }

    assert_equal 1, @reaper.reclaim!, 'a pre-nonce orphan is reclaimable during the upgrade window'
    assert_equal 1, llen(@public_queue)
  end

  # --- cluster lock ------------------------------------------------------

  def test_reap_is_a_noop_when_both_locks_are_held_elsewhere
    seed_private_list(DEAD_PID, %w[a])
    @pool.with do |c|
      c.call('SET', @lock_key, 'other', 'EX', 30)
      c.call('SET', @full_lock_key, 'other', 'EX', 30)
    end

    assert_equal 0, @reaper.reap, 'a process that loses both locks does not sweep'
    assert_equal 1, llen(private_list(DEAD_PID))
  end

  def test_reap_sweeps_when_the_lock_is_free
    seed_private_list(DEAD_PID, %w[a b])

    assert_equal 2, @reaper.reap
  end

  # Losing the scoped lock but winning the (separate) hourly lock still runs the
  # full sweep — the two gates are independent.
  def test_reap_runs_full_sweep_when_only_scoped_lock_is_held
    seed_private_list(DEAD_PID, %w[a b])
    @pool.with { |c| c.call('SET', @lock_key, 'other', 'EX', 30) }

    assert_equal 2, @reaper.reap, 'full sweep reclaims even when the scoped lock is lost'
  end

  # --- full-keyspace sweep (acceptance #4) -------------------------------

  # The headline gap: a private list whose public queue this process does NOT
  # serve (renamed/decommissioned queue, or a dead host's queue no survivor
  # consumes) is invisible to the scoped sweep but recovered by the full one.
  # rubocop:disable Minitest/MultipleAssertions
  # One scenario: scoped sweep misses it, full sweep recovers it onto the
  # foreign public queue and drains the private list. Cohesive — keep together.
  def test_reclaim_full_reclaims_orphan_in_an_unserved_queue
    foreign_q = Wurk::Keys.queue("#{@ns}-foreign")
    private_key = "#{foreign_q}|#{@host}|#{DEAD_PID}|0"
    @extra_keys.push(foreign_q, private_key)
    @pool.with { |c| c.call('RPUSH', private_key, payload('x'), payload('y')) }

    # Scoped sweep can't see it (foreign_q isn't a served queue)...
    assert_equal 0, @reaper.reclaim!, 'scoped sweep ignores unserved queues'
    # ...but the full sweep recovers it to its own public queue.
    assert_equal 2, @reaper.reclaim_full!
    assert_equal 0, llen(private_key), 'orphan private list drained'
    assert_equal 2, llen(foreign_q), 'jobs re-queued onto the foreign public queue'
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_reclaim_full_leaves_a_live_owners_list_untouched
    foreign_q = Wurk::Keys.queue("#{@ns}-live")
    # This very process — same incarnation, alive.
    private_key = "#{foreign_q}|#{@host}|#{Process.pid}|#{Wurk::Component::PROCESS_NONCE}|0"
    @extra_keys.push(foreign_q, private_key)
    @pool.with { |c| c.call('RPUSH', private_key, payload('z')) }

    assert_equal 0, @reaper.reclaim_full!, 'a live owner is never reclaimed'
    assert_equal 1, llen(private_key)
  end

  def test_reclaim_full_ignores_public_queues_and_malformed_keys
    @pool.with do |c|
      c.call('RPUSH', Wurk::Keys.queue("#{@ns}-plain"), payload('public')) # no pipe → not a private list
      c.call('RPUSH', "#{Wurk::Keys.queue("#{@ns}-bad")}|#{@host}|notapid|0", payload('bad'))
    end
    @extra_keys.push(Wurk::Keys.queue("#{@ns}-plain"), "#{Wurk::Keys.queue("#{@ns}-bad")}|#{@host}|notapid|0")

    assert_equal 0, @reaper.reclaim_full!
  end

  # The full sweep has its own parser (no known public-queue prefix to split
  # on), so the nonce shape needs its own case there.
  def test_reclaim_full_reclaims_a_nonce_keyed_orphan
    foreign_q = Wurk::Keys.queue("#{@ns}-nonced")
    private_key = "#{foreign_q}|#{@host}|#{DEAD_PID}|#{Wurk::Component::PROCESS_NONCE}|0"
    @extra_keys.push(foreign_q, private_key)
    @pool.with { |c| c.call('RPUSH', private_key, payload('x')) }

    assert_equal 1, @reaper.reclaim_full!
    assert_equal 1, llen(foreign_q), 'reclaimed onto the correctly-parsed public queue'
  end

  # The full sweep has no prefix to split on, so an all-digit host makes the
  # pre-nonce shape look like the nonce shape: read wide, `123456789012` is the
  # queue name's last segment and the queue name itself is gone. Such a list
  # holds a pre-upgrade process's in-flight jobs — it has to stay reclaimable.
  def test_reclaim_full_reclaims_a_pre_nonce_orphan_from_an_all_digit_host
    foreign_q = Wurk::Keys.queue("#{@ns}-legacy")
    private_key = "#{foreign_q}|123456789012|#{DEAD_PID}|0"
    @extra_keys.push(foreign_q, private_key)
    @pool.with { |c| c.call('RPUSH', private_key, payload('legacy')) }

    assert_equal 1, @reaper.reclaim_full!
    assert_equal 1, llen(foreign_q), 'reclaimed onto the queue the narrow reading recovers'
  end

  # Same host, current shape: the wide reading is the right one and must stay
  # preferred — read narrow, the job lands on `<queue>|123456789012`.
  def test_reclaim_full_reclaims_a_nonce_keyed_orphan_from_an_all_digit_host
    foreign_q = Wurk::Keys.queue("#{@ns}-digits")
    private_key = "#{foreign_q}|123456789012|#{DEAD_PID}|#{Wurk::Component::PROCESS_NONCE}|0"
    @extra_keys.push(foreign_q, private_key, "#{foreign_q}|123456789012")
    @pool.with { |c| c.call('RPUSH', private_key, payload('nonced')) }

    assert_equal 1, @reaper.reclaim_full!
    assert_equal 1, llen(foreign_q), 'reclaimed onto the queue the wide reading recovers'
  end

  # A `|` inside the queue name must still parse: the owner segments are taken
  # from the right, so the public queue is everything before host|pid|nonce|idx.
  def test_reclaim_full_tolerates_a_pipe_in_the_queue_name
    foreign_q = Wurk::Keys.queue("#{@ns}|piped")
    private_key = "#{foreign_q}|#{@host}|#{DEAD_PID}|0"
    @extra_keys.push(foreign_q, private_key)
    @pool.with { |c| c.call('RPUSH', private_key, payload('p')) }

    assert_equal 1, @reaper.reclaim_full!
    assert_equal 1, llen(foreign_q), 'reclaimed onto the correctly-parsed public queue'
  end

  # --- thread lifecycle --------------------------------------------------

  def test_start_is_idempotent_and_stop_joins # rubocop:disable Minitest/MultipleAssertions
    refute_predicate @reaper, :running?
    first = @reaper.start
    second = @reaper.start

    assert_same first, second, 'start must not spawn a second thread'
    assert_predicate @reaper, :running?

    @reaper.stop

    refute_predicate @reaper, :running?
  end

  # stop while the loop is parked in wait_next: the CV signal wakes the thread,
  # which then sees @done and breaks (run_loop's `break if done?` THEN side).
  def test_stop_breaks_the_loop_once_it_is_parked_waiting
    reaper = Wurk::Fetcher::Reaper.new(@config, interval: 60, lock_key: "#{Wurk::Fetcher::Reaper::LOCK_KEY}:#{@ns}-park")
    thread = reaper.start
    wait_until { thread.status == 'sleep' } # parked on the ConditionVariable

    assert_equal 'sleep', thread.status, 'loop must be blocked in wait_next before we signal stop'

    reaper.stop

    refute_predicate reaper, :running?, 'a signalled, done loop must break and the thread join'
  end

  # The full-keyspace sweep is exactly the tick that outlasts a stop, and waiting
  # it out held the whole process teardown open past the swarm parent's shutdown
  # grace — which SIGKILLs the child mid-drain, the outcome this reaper exists to
  # recover from. Bounded at TimerLoop::JOIN_TIMEOUT like every other periodic
  # component.
  def test_stop_bounds_the_join_of_a_sweep_that_will_not_finish
    reaper = Wurk::Fetcher::Reaper.new(@config, interval: 60, lock_key: "#{Wurk::Fetcher::Reaper::LOCK_KEY}:#{@ns}-wedged")
    wedged = never_joins_thread
    reaper.instance_variable_set(:@thread, wedged)

    reaper.stop

    assert_equal [Wurk::TimerLoop::JOIN_TIMEOUT], wedged.joins, 'the join must carry a timeout'
    assert_same wedged, reaper.instance_variable_get(:@thread),
                'a straggler stays referenced so a restart cannot spawn a second sweep loop'
  end

  def test_stop_clears_the_thread_once_the_sweep_joins
    reaper = Wurk::Fetcher::Reaper.new(@config, interval: 60, lock_key: "#{Wurk::Fetcher::Reaper::LOCK_KEY}:#{@ns}-joins")
    reaper.start

    reaper.stop

    assert_nil reaper.instance_variable_get(:@thread)
  end

  # A short interval lets wait_next time out while @done is still false, so the
  # loop falls through to tick_once (run_loop's `break if done?` ELSE side, plus
  # wait_next's `unless @done` THEN side: it actually waited).
  def test_loop_ticks_when_the_wait_times_out_before_stop
    reaper = Wurk::Fetcher::Reaper.new(@config, interval: 0.05, lock_key: "#{Wurk::Fetcher::Reaper::LOCK_KEY}:#{@ns}-tick")
    ticks = Queue.new
    reaper.define_singleton_method(:reap) { ticks << :tick }

    reaper.start
    first = ticks.pop # blocks until the loop has tick_once'd at least once

    assert_equal :tick, first, 'a timed-out wait must lead to a tick_once'
  ensure
    reaper.stop
  end

  # --- tick_once exception forwarding ------------------------------------

  # tick_once swallows a sweep error and forwards it via handle_exception when
  # the config supports it (the real Configuration does). THEN side of the
  # `@config.respond_to?(:handle_exception)` guard.
  def test_tick_once_forwards_a_sweep_error_when_config_can_handle_it
    @reaper.define_singleton_method(:reap) { raise 'sweep blew up' }

    # Must not propagate; the error is reported through the (NULL-logger) config.
    assert_nil(begin
      @reaper.send(:tick_once)
      nil
    rescue StandardError => e
      e
    end, 'a sweep error must be swallowed, not raised out of the loop')
  end

  # ELSE side: a config object with no #handle_exception. The rescue must still
  # swallow the error rather than blow up the loop thread. reap is stubbed to
  # raise before it touches Redis, so the bare config is never asked for a pool.
  def test_tick_once_swallows_a_sweep_error_when_config_cannot_handle_it
    bare = Object.new

    refute_respond_to bare, :handle_exception
    reaper = Wurk::Fetcher::Reaper.new(bare)
    reaper.define_singleton_method(:reap) { raise 'sweep blew up' }

    assert_nil reaper.send(:tick_once)
  end

  # --- wait_next short-circuit -------------------------------------------

  # When @done is already set, wait_next must return immediately without parking
  # on the ConditionVariable for the (deliberately huge) interval. ELSE side of
  # `@sleeper.wait(...) unless @done`.
  def test_wait_next_returns_immediately_when_already_done
    reaper = Wurk::Fetcher::Reaper.new(@config, interval: 3600, lock_key: "#{Wurk::Fetcher::Reaper::LOCK_KEY}:#{@ns}-done")
    reaper.instance_variable_set(:@done, true)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    reaper.send(:wait_next)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1.0, 'a done reaper must not wait out the interval'
  end

  # --- multi-iteration SCAN ----------------------------------------------

  # More private lists than SCAN_COUNT forces each_private_list to loop on a
  # non-zero cursor (the `break if cursor == "0"` ELSE side). All lists belong
  # to this live process, so none are reclaimed but every page is scanned.
  def test_scan_pages_through_many_private_lists_without_reclaiming_live_ones
    count = Wurk::Fetcher::Reaper::SCAN_COUNT * 3
    seed_many_private_lists(count)

    assert_equal 0, @reaper.reclaim!, 'live-owned lists survive a multi-page scan'
    assert_equal count, scanned_private_list_count, 'every paged private list is still present'
  ensure
    delete_many_private_lists
  end

  # --- key parsing edge: prefix mismatch ---------------------------------

  # parse_owner guards against a key that does not carry the public-queue
  # prefix (delete_prefix returns the string unchanged → suffix == key). This
  # cannot arise through reclaim! (SCAN MATCHes `<public_q>|*`), so it is
  # exercised directly: the THEN side of `return [nil, nil] if suffix == key`.
  def test_parse_owner_rejects_a_key_without_the_public_queue_prefix
    host, pid = @reaper.send(:parse_owner, @public_queue, 'an-unrelated-key')

    assert_nil host
    assert_nil pid
  end

  private

  # A pid this process can be sure is not running, distinct per test so the
  # heartbeat one test registers under it can never make a peer's orphan read
  # as live (the `processes` SET is global to the worker's Redis DB).
  def unowned_pid
    @unowned_pid ||= 990_000 + (object_id % 9_000)
  end

  # Stands in for a sweep still SCANning when the stop lands: `join` records the
  # timeout it was given and reports "not finished" (nil), exactly as a real
  # thread that outlives the bound does. Cheaper and more precise than waiting a
  # real JOIN_TIMEOUT out.
  def never_joins_thread
    thread = Object.new
    joins = []
    thread.define_singleton_method(:joins) { joins }
    thread.define_singleton_method(:alive?) { true }
    thread.define_singleton_method(:join) { |timeout| joins << timeout and nil }
    thread
  end

  def wait_until(timeout: 5.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep(0.005) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def seed_many_private_lists(count)
    @pool.with do |c|
      count.times { |i| c.call('RPUSH', "#{private_list(Process.pid)}:#{i}", payload("p#{i}")) }
    end
  end

  def delete_many_private_lists
    @pool.with do |c|
      keys = c.call('KEYS', "#{private_list(Process.pid)}:*")
      c.call('DEL', *keys) unless keys.empty?
    end
  end

  def scanned_private_list_count
    @pool.with { |c| c.call('KEYS', "#{private_list(Process.pid)}:*").size }
  end

  def seed_private_list(pid, tokens, host: @host, nonce: Wurk::Component::PROCESS_NONCE)
    key = private_list(pid, host: host, nonce: nonce)
    @pool.with { |c| tokens.each { |t| c.call('RPUSH', key, payload(t)) } }
    key
  end

  # `nonce: nil` yields the pre-nonce shape a process running the previous
  # release would have written.
  def private_list(pid, host: @host, nonce: Wurk::Component::PROCESS_NONCE)
    return "#{@public_queue}|#{host}|#{pid}|0" if nonce.nil?

    "#{@public_queue}|#{host}|#{pid}|#{nonce}|0"
  end

  def payload(token, jid: nil)
    Wurk.dump_json('class' => 'ReaperTestJob', 'args' => [token],
                   'queue' => @queue_name, 'jid' => jid || "#{@salt}:#{token}")
  end

  def recovery_key(jid)
    "#{Wurk::Middleware::PoisonPill::KEY_PREFIX}#{jid}"
  end

  # Returns the nonce of the registered identity so a caller can key a private
  # list to the very process it just gave a heartbeat to.
  def register_process(host, pid, info:, nonce: SecureRandom.hex(6))
    identity = "#{host}:#{pid}:#{nonce}"
    @registered ||= {}
    @registered[[host, pid]] = identity
    Wurk.redis do |c|
      c.call('SADD', Wurk::Keys::PROCESSES, identity)
      c.call('HSET', identity, 'info', '{}') if info
    end
    nonce
  end

  def unregister_process(host, pid)
    identity = @registered&.delete([host, pid])
    return unless identity

    Wurk.redis do |c|
      c.call('SREM', Wurk::Keys::PROCESSES, identity)
      c.call('DEL', identity)
    end
  end

  def dead_payloads
    Wurk.redis { |c| c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1) }
  end

  def cleanup_dead_set
    Wurk.redis do |c|
      mine = c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1).select { |m| m.include?(@queue_name) }
      c.call('ZREM', Wurk::Keys::DEAD, *mine) unless mine.empty?
    end
  end

  def cleanup_recovery_counters
    Wurk.redis do |c|
      keys = c.call('KEYS', "#{Wurk::Middleware::PoisonPill::KEY_PREFIX}#{@salt}:*")
      c.call('DEL', *keys) unless keys.empty?
    end
  end

  def llen(key)
    @pool.with { |c| c.call('LLEN', key) }
  end

  def lindex(key, idx)
    @pool.with { |c| c.call('LINDEX', key, idx) }
  end
end
