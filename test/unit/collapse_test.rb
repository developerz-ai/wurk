# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Wurk::Collapse — the `collapse:` option and the client middleware that acts on
# it, against real Redis.
#
# Three contracts carry this layer and every test below defends one: a typo in
# the declaration fails at the class rather than at the first push, a class gets
# exactly one collapse policy, and a policy that cannot work where it was put —
# bulk, a batch, an explicit `at` — fails the push instead of quietly doing
# nothing.
#
# Parallel safety: every payload's class name is derived from this test's
# namespace, so its identity digest and every key hanging off it are unique to
# this test; the per-worker DB and the teardown FLUSHDB do the rest.
class CollapseTest < Wurk::Test::UnitCase
  parallelize_me!

  # Long enough that nothing under test is promoted mid-assertion by a scheduler
  # running in another suite.
  WAIT = 30
  # An hour, so a slot boundary landing inside a test is not a flake budget.
  SLOT = 3600

  def setup
    super
    @queue      = "q-#{Process.pid}-#{object_id}"
    @class_name = "CollapseJob@#{Process.pid}-#{object_id}"
    @pool       = Wurk.configuration.redis_pool
    @pool.with { |conn| Wurk::Lua::Loader.script_load_all(conn) }
  end

  # --- option shape ----------------------------------------------------

  # `sidekiq-unique-jobs` v8.1.0 still recognizes `sidekiq_options unique:` as
  # the deprecated spelling of its own `lock:`, so claiming that key would have
  # this validator reject a host's working declaration. Pinned because the name
  # is the kind of thing a later reader "tidies" back.
  def test_the_option_key_is_not_one_the_ecosystem_already_claims
    assert_equal 'collapse', Wurk::Collapse::OPTION
    refute_includes %w[unique lock unique_args unique_prefix], Wurk::Collapse::OPTION
  end

  def test_absent_option_declares_no_policy
    assert_nil Wurk::Collapse.policy_for({})
    assert_nil Wurk::Collapse.policy_for('class' => @class_name, 'args' => [])
  end

  def test_debounce_parses_into_the_keywords_debounce_takes
    policy = Wurk::Collapse.policy_for(options(policy: :debounce, wait: 5, max_wait: 60))

    assert_equal :debounce, policy.name
    assert_equal({ wait: 5, max_wait: 60 }, policy.params)
  end

  def test_throttle_parses_into_the_keywords_throttle_takes
    policy = Wurk::Collapse.policy_for(options(policy: :throttle, slot: 60))

    assert_equal :throttle, policy.name
    assert_equal({ slot: 60 }, policy.params)
  end

  # A payload that has crossed Redis carries the JSON spelling of whatever the
  # class declared, so both have to parse to the same policy.
  def test_string_keys_and_values_parse_identically_to_symbols
    from_json = Wurk::Collapse.policy_for(options('policy' => 'debounce', 'wait' => 5))

    assert_equal Wurk::Collapse.policy_for(options(policy: :debounce, wait: 5)), from_json
  end

  def test_declaration_survives_a_round_trip_through_json
    declared = { policy: :debounce, wait: 5, max_wait: 60 }
    revived = Wurk.load_json(Wurk.dump_json(options(declared)))

    assert_equal Wurk::Collapse.policy_for(options(declared)), Wurk::Collapse.policy_for(revived)
  end

  # --- a typo fails loudly ---------------------------------------------

  def test_unknown_policy_name_is_rejected
    error = assert_raises(Wurk::Collapse::ConfigurationError) do
      Wurk::Collapse.policy_for(options(policy: :dbounce, wait: 5))
    end

    assert_match(/unknown collapse policy :dbounce/, error.message)
    assert_match(/:debounce and :throttle/, error.message)
  end

  def test_missing_policy_name_is_rejected
    assert_raises(Wurk::Collapse::ConfigurationError) { Wurk::Collapse.policy_for(options(wait: 5)) }
  end

  def test_non_hash_declaration_is_rejected
    assert_raises(Wurk::Collapse::ConfigurationError) { Wurk::Collapse.policy_for('collapse' => 5) }
    assert_raises(Wurk::Collapse::ConfigurationError) { Wurk::Collapse.policy_for('collapse' => :debounce) }
  end

  def test_missing_required_parameter_is_rejected
    error = assert_raises(Wurk::Collapse::ConfigurationError) do
      Wurk::Collapse.policy_for(options(policy: :throttle))
    end

    assert_match(/requires :slot/, error.message)
  end

  # The whole reason the parameter set is closed: `slot:` on a debounce is
  # `wait:` mistyped, and one mistake should not need two trips to fix.
  def test_wrong_policys_parameter_names_both_faults_at_once
    error = assert_raises(Wurk::Collapse::ConfigurationError) do
      Wurk::Collapse.policy_for(options(policy: :debounce, slot: 5))
    end

    assert_match(/requires :wait/, error.message)
    assert_match(/does not take :slot/, error.message)
  end

  def test_unknown_extra_parameter_is_rejected
    error = assert_raises(Wurk::Collapse::ConfigurationError) do
      Wurk::Collapse.policy_for(options(policy: :throttle, slot: 60, jitter: 3))
    end

    assert_match(/does not take :jitter/, error.message)
  end

  def test_non_positive_seconds_are_rejected
    [0, -1, 'soon', nil, Float::INFINITY].each do |value|
      assert_raises(Wurk::Collapse::ConfigurationError) do
        Wurk::Collapse.policy_for(options(policy: :debounce, wait: value))
      end
    end
  end

  # A slot boundary is a wall-clock landmark every producer has to land on
  # identically, so it cannot be a fraction of a second. A quiet period can.
  def test_fractional_throttle_slot_is_rejected_but_fractional_wait_is_not
    assert_raises(Wurk::Collapse::ConfigurationError) do
      Wurk::Collapse.policy_for(options(policy: :throttle, slot: 1.5))
    end
    assert_in_delta 1.5, Wurk::Collapse.policy_for(options(policy: :debounce, wait: 1.5)).params[:wait]
  end

  # Refused at the class, not at the first push: Wurk::Debounce refuses it too,
  # but only once someone enqueues.
  def test_max_wait_below_wait_is_rejected
    error = assert_raises(Wurk::Collapse::ConfigurationError) do
      Wurk::Collapse.policy_for(options(policy: :debounce, wait: 10, max_wait: 5))
    end

    assert_match(/max_wait/, error.message)
  end

  # --- one policy per class --------------------------------------------

  def test_declaring_a_policy_alongside_unique_for_is_rejected
    error = assert_raises(Wurk::Collapse::ConfigurationError) do
      Wurk::Collapse.policy_for(options({ policy: :debounce, wait: 5 }, 'unique_for' => 60))
    end

    assert_match(/unique_for/, error.message)
    assert_match(/collapse/, error.message)
  end

  # `unique_for: false` is the documented opt-out and reads as absent.
  def test_unique_for_false_is_not_a_conflict
    policy = Wurk::Collapse.policy_for(options({ policy: :debounce, wait: 5 }, 'unique_for' => false))

    assert_equal :debounce, policy.name
  end

  def test_worker_class_declaring_both_raises_at_definition
    assert_raises(Wurk::Collapse::ConfigurationError) do
      worker_class(unique_for: 60, collapse: { policy: :debounce, wait: 5 })
    end
  end

  def test_worker_class_declaring_a_typo_raises_at_definition
    assert_raises(Wurk::Collapse::ConfigurationError) do
      worker_class(collapse: { policy: :debounce, wait: -1 })
    end
  end

  # Only the merge can see this one: the subclass declares a policy and inherits
  # the lock.
  def test_subclass_inheriting_unique_for_and_adding_a_policy_raises
    parent = worker_class(unique_for: 60)

    assert_raises(Wurk::Collapse::ConfigurationError) do
      Class.new(parent) { sidekiq_options collapse: { policy: :throttle, slot: 60 } }
    end
  end

  # A rejected declaration must leave the class holding what it had.
  def test_a_rejected_declaration_does_not_mutate_the_class_options
    klass = worker_class(queue: 'kept')

    assert_raises(Wurk::Collapse::ConfigurationError) { klass.sidekiq_options collapse: { policy: :nope } }
    assert_equal 'kept', klass.get_sidekiq_options['queue']
    refute klass.get_sidekiq_options.key?('collapse')
  end

  # The ActiveJob options module is deliberately identical to the worker DSL: an
  # AJ class has to be told about a bad value in the same place a plain worker is.
  def test_active_job_options_module_validates_the_same_way
    klass = Class.new { include Wurk::Job::Options }

    assert_raises(Wurk::Collapse::ConfigurationError) do
      klass.sidekiq_options collapse: { policy: :debounce, slot: 5 }
    end

    klass.sidekiq_options collapse: { policy: :debounce, wait: 5 }

    assert_equal :debounce, Wurk::Collapse.policy_for(klass.get_sidekiq_options).name
  end

  # --- the middleware: debounce ----------------------------------------

  # Same identity — the digest is [class, queue, args] — five pushes deep. The
  # last one's payload is the one left standing.
  def test_debounce_collapses_a_burst_to_one_scheduled_entry_with_the_last_payload
    5.times { |i| assert_nil invoke(debounced({ 'note' => i }, jid: "j#{i}")) }

    assert_equal 1, scheduled.size
    assert_equal 4, scheduled.first['note']
    assert_equal 'j4', scheduled.first['jid']
  end

  # Nothing reaches the queue: the payload is written by the script, and the
  # push it came from is halted before Client writes anything.
  def test_debounce_returns_nil_and_writes_nothing_to_the_queue
    assert_nil invoke(debounced)
    assert_equal(0, @pool.with { |conn| conn.call('LLEN', Wurk::Keys.queue(@queue)) })
  end

  # Why the decision is taken on the way *out* of the chain: the stored member is
  # the payload every inner middleware has already stamped, not a stripped cousin.
  def test_the_stored_member_carries_what_inner_middleware_stamped
    job = debounced

    invoke(job) do
      job['locale'] = 'pt-BR'
      job
    end

    assert_equal 'pt-BR', scheduled.first['locale']
  end

  # An ordinary `schedule` member: canonical score format, `at`/`enqueued_at`
  # stripped, and readable by the plain inspector.
  def test_the_stored_member_is_an_ordinary_scheduled_job
    invoke(debounced)
    member, score = raw_scheduled.first

    assert_in_delta Time.now.to_f + WAIT, score.to_f, 5
    refute JSON.parse(member).key?('at')
    refute JSON.parse(member).key?('enqueued_at')
    assert_equal(1, Wurk::ScheduledSet.new.count { |entry| entry.klass == @class_name })
  end

  # --- the middleware: throttle ----------------------------------------

  def test_throttle_admits_the_first_and_drops_the_rest_of_the_slot
    job = throttled(jid: 'first')

    assert_same job, invoke(job)
    assert_nil invoke(throttled(jid: 'second'))
    assert_nil invoke(throttled(jid: 'third'))
  end

  # An admitted job takes the ordinary path: the chain hands its payload straight
  # back, so Client writes it exactly as it would with no policy at all.
  def test_an_admitted_throttled_push_writes_nothing_of_its_own
    invoke(throttled(jid: 'first'))

    assert_equal 0, scheduled.size
  end

  # --- incompatible company --------------------------------------------

  def test_debounce_inside_a_batch_is_rejected
    error = assert_raises(Wurk::Collapse::ConfigurationError) { invoke(debounced({ 'bid' => 'b-1' })) }

    assert_match(/batch/, error.message)
    assert_equal 0, scheduled.size
  end

  # Admitted it takes the ordinary batched path; dropped it is simply not in the
  # batch, exactly as a duplicate dropped by Wurk::Unique is not.
  def test_throttle_inside_a_batch_is_allowed
    job = throttled({ 'bid' => 'b-1' }, jid: 'first')

    assert_same job, invoke(job)
    assert_nil invoke(throttled({ 'bid' => 'b-1' }, jid: 'second'))
  end

  def test_debounce_with_an_explicit_at_is_rejected
    error = assert_raises(Wurk::Collapse::ConfigurationError) do
      invoke(debounced({ 'at' => Time.now.to_f + 3600 }))
    end

    assert_match(/fire time/, error.message)
    assert_equal 0, scheduled.size
  end

  def test_throttle_with_an_explicit_at_is_allowed
    job = throttled({ 'at' => Time.now.to_f + 3600 })

    assert_same job, invoke(job)
  end

  # `encrypt: true` with no crypto configured is inert, so the policy proceeds —
  # the mirror of Unique's own "crypto disabled" case.
  def test_encrypt_option_without_encryption_enabled_is_untouched
    assert_nil invoke(debounced({ 'encrypt' => true }))
    assert_equal 1, scheduled.size
  end

  # --- bulk ------------------------------------------------------------

  def test_push_bulk_rejects_a_class_level_policy
    klass = worker_class(collapse: { policy: :debounce, wait: 5 })
    error = assert_raises(Wurk::Collapse::ConfigurationError) { klass.perform_bulk([[1], [2]]) }

    assert_match(/push_bulk/, error.message)
  end

  def test_push_bulk_rejects_a_per_call_policy
    assert_raises(Wurk::Collapse::ConfigurationError) do
      Wurk::Client.new(pool: @pool).push_bulk(
        'class' => @class_name, 'queue' => @queue, 'args' => [[1]],
        'collapse' => { 'policy' => 'throttle', 'slot' => SLOT }
      )
    end
  end

  # Rejected before anything is written, not halfway through the slices.
  def test_a_rejected_bulk_writes_nothing
    klass = worker_class(collapse: { policy: :throttle, slot: 60 })

    assert_raises(Wurk::Collapse::ConfigurationError) { klass.perform_bulk(Array.new(50) { |i| [i] }) }
    assert_equal(0, @pool.with { |conn| conn.call('LLEN', Wurk::Keys.queue(@queue)) })
  end

  def test_push_bulk_without_a_policy_is_untouched
    klass = worker_class

    assert_equal 2, klass.perform_bulk([[1], [2]]).compact.size
  end

  # --- chain position --------------------------------------------------

  # The decision is taken on the way out of the chain so the payload it writes
  # is fully stamped, which only holds from the outermost slot. `add` appends,
  # so every middleware a host installs at boot — Unique.enable!,
  # Encryption.enable!, Telemetry.install! — has to land inside this one.
  def test_registered_outermost_on_the_default_client_chain
    chain = Wurk.configuration.client_middleware

    assert_equal Wurk::Collapse::ClientMiddleware, chain.entries.first.klass
  end

  def test_a_middleware_installed_later_lands_inside_the_collapse_decision
    later = Class.new
    Wurk.configuration.client_middleware.add(later)
    klasses = Wurk.configuration.client_middleware.entries.map(&:klass)

    assert_operator klasses.index(Wurk::Collapse::ClientMiddleware), :<, klasses.index(later)
  ensure
    Wurk.configuration.client_middleware.remove(later)
  end

  # Client walks the args of whatever the chain hands back — after this
  # middleware has already halted it — so the one payload Client never verifies
  # is the one written from in here.
  def test_a_debounced_payload_is_still_walked_for_non_json_args
    assert_raises(ArgumentError) { invoke(debounced(args: [:not_json])) }
    assert_equal 0, scheduled.size
  end

  # --- nothing declared, nothing done ----------------------------------

  def test_a_job_without_the_option_passes_straight_through
    plain = { 'class' => @class_name, 'args' => [1], 'queue' => @queue, 'jid' => 'plain' }

    assert_same plain, invoke(plain)
    assert_equal 0, scheduled.size
  end

  # The middleware halts on a nil from the rest of the chain rather than acting
  # on a payload something downstream already dropped.
  def test_a_policy_job_halted_downstream_is_not_collapsed
    assert_nil(invoke(debounced) { nil })
    assert_equal 0, scheduled.size
  end

  private

  def options(declared, extra = {})
    { 'class' => @class_name, 'collapse' => declared }.merge(extra)
  end

  def debounced(extra = {}, args: [1], jid: 'seed')
    payload(extra, args, jid).merge('collapse' => { 'policy' => 'debounce', 'wait' => WAIT })
  end

  def throttled(extra = {}, args: [1], jid: 'seed')
    payload(extra, args, jid).merge('collapse' => { 'policy' => 'throttle', 'slot' => SLOT })
  end

  def payload(extra, args, jid)
    { 'class' => @class_name, 'args' => args, 'queue' => @queue, 'jid' => jid,
      'created_at' => 1_700_000_000.0 }.merge(extra)
  end

  # Drives the real middleware. The default tail stands in for the innermost
  # block {Wurk::Client#push} yields — it hands the payload straight back — and a
  # given block stands in for a middleware registered inside this one.
  def invoke(job, &tail)
    tail ||= -> { job }
    Wurk::Collapse::ClientMiddleware.new.call(nil, job, job['queue'], @pool) { tail.call }
  end

  # ZRANGE the shared zset and keep only this test's members. Sibling suites
  # write non-JSON probe members there; skip those rather than blow up.
  def raw_scheduled
    @pool.with { |conn| conn.call('ZRANGE', 'schedule', 0, -1, 'WITHSCORES') }.filter_map do |member, score|
      [member, score] if JSON.parse(member)['class'] == @class_name
    rescue JSON::ParserError
      next
    end
  end

  def scheduled = raw_scheduled.map { |member, _score| JSON.parse(member) }

  # Anonymous, so nothing is left on Object for a sibling test to trip over.
  def worker_class(**opts)
    queue = @queue
    Class.new do
      include Wurk::Worker

      sidekiq_options({ queue: queue }.merge(opts))
    end
  end
end

# The two cases that touch process-wide state — `Wurk::Encryption.enable` and
# the global logger — split out here for the same reason UniqueTest is not
# parallelized: either one leaking sideways would break a sibling's assertion.
class CollapseGlobalStateTest < Wurk::Test::UnitCase
  # NOT parallelize_me!

  def setup
    super
    @queue = "q-#{Process.pid}-#{object_id}"
    @class_name = "CollapseLogJob@#{Process.pid}-#{object_id}"
    @pool = Wurk.configuration.redis_pool
    @pool.with { |conn| Wurk::Lua::Loader.script_load_all(conn) }
  end

  # The incumbent's jid is the one fact a dropped push cannot recover for itself
  # afterwards, and is why Throttle::Outcome carries it at all.
  def test_a_dropped_throttle_names_the_jid_that_beat_it
    log = capture_log do
      invoke(throttled('first'))
      invoke(throttled('second'))
    end

    assert_match(/throttled .* dropped/, log)
    assert_match(/jid=second blocked by jid=first/, log)
  end

  # Debug, not info: a burst is many pushes by construction and every one of them
  # lands here, so info would be a log line per enqueue at exactly the rate this
  # policy exists to absorb.
  def test_a_debounce_that_replaces_a_pending_sibling_logs_at_debug
    log = capture_log(Logger::DEBUG) do
      invoke(debounced('first'))
      invoke(debounced('second'))
    end

    assert_equal 1, log.scan('replaced the pending job').size
    assert_match(/jid=second/, log)
    refute_match(/replaced the pending job/, capture_log { invoke(debounced('third')) })
  end

  def test_encrypted_job_with_a_policy_is_rejected
    with_crypto do
      job = { 'class' => 'CollapseEncJob', 'queue' => 'q', 'args' => ['s'], 'jid' => 'enc-1',
              'encrypt' => true, 'collapse' => { 'policy' => 'debounce', 'wait' => 30 } }

      error = assert_raises(Wurk::Collapse::ConfigurationError) do
        Wurk::Collapse::ClientMiddleware.new.call(nil, job, job['queue'], Wurk.configuration.redis_pool) { job }
      end

      assert_match(/collapse/, error.message)
      assert_match(/encrypt/, error.message)
    end
  end

  def test_encrypted_job_without_a_policy_is_untouched
    with_crypto do
      job = { 'class' => 'CollapseEncJob', 'queue' => 'q', 'args' => ['s'], 'jid' => 'enc-2', 'encrypt' => true }

      assert_same job, Wurk::Collapse::ClientMiddleware.new
                                                       .call(nil, job, job['queue'], Wurk.configuration.redis_pool) {
                                                         job
                                                       }
    end
  end

  private

  def with_crypto
    Wurk::Encryption.enable(active_version: 1) { |_v| 'k' * 32 }
    yield
  ensure
    Wurk::Encryption.disable!
    Wurk.configuration.client_middleware.remove(Wurk::Encryption::ClientMiddleware)
    Wurk.configuration.server_middleware.remove(Wurk::Encryption::ServerMiddleware)
  end

  def debounced(jid)
    { 'class' => @class_name, 'args' => [1], 'queue' => @queue, 'jid' => jid,
      'collapse' => { 'policy' => 'debounce', 'wait' => 30 } }
  end

  def throttled(jid)
    { 'class' => @class_name, 'args' => [1], 'queue' => @queue, 'jid' => jid,
      'collapse' => { 'policy' => 'throttle', 'slot' => 3600 } }
  end

  def invoke(job)
    Wurk::Collapse::ClientMiddleware.new.call(nil, job, job['queue'], @pool) { job }
  end

  # Swap in a StringIO logger for the block and return what it captured, without
  # disturbing the global IO::NULL logger the rest of the suite relies on.
  def capture_log(level = Logger::INFO)
    io = StringIO.new
    previous = Wurk.logger
    Wurk.logger = Logger.new(io, level: level)
    begin
      yield
      io.string
    ensure
      Wurk.logger = previous
    end
  end
end
