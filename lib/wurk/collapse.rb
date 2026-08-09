# frozen_string_literal: true

require_relative 'debounce'
require_relative 'job_util'
require_relative 'middleware'
require_relative 'throttle'
require_relative 'unique'

module Wurk
  # The enqueue door for Wurk's two collapse policies. {Wurk::Debounce} and
  # {Wurk::Throttle} are the mechanisms; this is the single option a worker
  # class writes to reach them, and the one place the company they cannot keep
  # is refused.
  #
  #   sidekiq_options collapse: { policy: :debounce, wait: 5, max_wait: 60 }
  #   sidekiq_options collapse: { policy: :throttle, slot: 60 }
  #
  # ## Why `collapse:` rather than `unique:`
  #
  # The slice plan sketched `unique: { policy: … }`, on the reasonable grounds
  # that all three policies share one identity digest and one narrowing hook
  # (`sidekiq_unique_context`). That name is taken. `sidekiq-unique-jobs` v8.1.0
  # — the gem this feature replaces, and one Wurk's ecosystem suite runs against
  # — still recognizes `sidekiq_options unique:` as the deprecated spelling of
  # its own `lock:` (`SidekiqUniqueJobs::Lock::Validator::DEPRECATED_KEYS` maps
  # `:unique => :lock`). Claiming the key would make this validator reject a
  # host's working pre-v6 declaration, which is the drop-in contract breaking on
  # exactly the gem it is meant to make unnecessary. `collapse` is unclaimed
  # there, and says what both policies do.
  #
  # ## One policy per class
  #
  # `collapse:` and `unique_for:` answer the same question differently — collapse
  # a burst, or reject the duplicate — and they do not compose: a lock drops the
  # very re-enqueue debounce needs in order to extend a burst, and which of the
  # two won would come down to client-chain registration order. A class declares
  # one; declaring both is refused where it was written.
  #
  # ## What a collapsed enqueue returns
  #
  # nil, from both policies. For a dropped throttle that is {Wurk::Throttle}'s
  # documented answer and {Wurk::Unique}'s long-standing one. For a debounce it
  # is the less obvious half: this push's payload really is in `schedule`, under
  # this push's jid — but only until the next enqueue of the same identity
  # replaces it, so a jid handed back here invites a caller to poll, or cancel, a
  # member a sibling push has already ZREM'd. {Wurk::Debounce.schedule} returns
  # its {Wurk::Debounce::Outcome} for code that needs the detail; the enqueue
  # door does not.
  module Collapse
    # The job-hash key, and the `sidekiq_options` key it is written as.
    OPTION = 'collapse'

    # Everything refused here is a configuration mistake, and every door this
    # guards already answers a bad option with an ArgumentError
    # (`JobUtil.validate_track!`, `.validate_bounds!`). Subclassing keeps a host
    # that rescues ArgumentError around a declaration working, while leaving the
    # conflicts nameable on their own.
    class ConfigurationError < ArgumentError; end

    # A parsed declaration: the policy's name, plus the keyword arguments its
    # module takes, ready to splat into {Wurk::Debounce.schedule} or
    # {Wurk::Throttle.admit}. Parsing straight into the callee's own keywords is
    # what stops this file from growing a second opinion about what `wait` means.
    Policy = Struct.new(:name, :params)

    # Per-policy parameter rules. `whole` marks a slot boundary, which is a
    # wall-clock landmark every producer has to land on identically and so
    # cannot be a fraction of a second ({Wurk::Throttle} refuses one too).
    #
    # Values are checked here and not left to the two modules, which raise at
    # enqueue: a `slot: 1.5` that only fails the first time a rarely-exercised
    # worker is pushed has already shipped.
    PARAMS = {
      debounce: { required: %i[wait].freeze, optional: %i[max_wait].freeze, whole: false },
      throttle: { required: %i[slot].freeze, optional: [].freeze, whole: true }
    }.freeze

    class << self
      # The collapse policy a set of job options declares, or nil for none.
      #
      # Parsing and validating are one pass, shared by every door: both
      # `sidekiq_options` copies (worker and ActiveJob), which keep only the
      # raising, and {ClientMiddleware}, which acts on the result. One definition
      # means "valid where it was written" and "usable where it is read" cannot
      # drift apart — the same reason {Wurk::JobUtil.positive_seconds?} is shared
      # rather than reimplemented per reader.
      #
      # Strict on every axis, deliberately: `slot:` written on a debounce is a
      # typo for `wait:`, and a silently ignored one leaves a worker collapsing
      # on a default nobody chose.
      #
      # @param options [Hash] string-keyed job options or a job payload
      # @return [Policy, nil]
      # @raise [ConfigurationError]
      def policy_for(options)
        declared = options[OPTION]
        return nil if declared.nil?

        reject_unique!(options, declared)
        params = symbolized(declared)
        name = policy_name!(params.delete(:policy), declared)
        check_keys!(name, params, declared)
        check_seconds!(name, params, declared)
        reject_short_cap!(params, declared) if name == :debounce
        Policy.new(name, params)
      end

      # `push_bulk` exists to amortize one round trip across many jobs: a
      # same-queue bulk of 1,000 is still the one SADD + variadic LPUSH pipeline
      # a single push is. A collapse policy is a decision per job — an EVALSHA
      # whose KEYS are that job's own identity — so it cannot ride that pipeline,
      # and applying it per item turns the one round trip into N. Measured here,
      # 1,000 jobs onto a loopback Redis, `INFO commandstats` either side:
      #
      #   push_bulk, no policy   ~14 ms    2 commands,     1 round trip
      #   per-item collapse     ~320 ms    6,000 commands, 1,000 round trips
      #
      # ~22x wall clock and three orders of magnitude of round trips, and both
      # grow with the batch. That is a structural cost, not a constant worth
      # tuning away, which is what settles step 6 of the slice plan against
      # applying policies per item.
      #
      # It is also meaningless in the shape bulk is used: `perform_bulk` pushes
      # one class with N distinct argument lists, and distinct arguments are
      # distinct identities, so nothing collapses with anything. Every jid in the
      # returned array would come back nil, which in `push_bulk`'s contract means
      # "middleware halted this one" — indistinguishable from a debounce that did
      # write. Raising is the only outcome that is neither a silent regression
      # nor a lie about what happened.
      #
      # @raise [ConfigurationError] when the class or the call declares a policy
      def reject_bulk!(klass, declared)
        return if declared.nil?

        raise ConfigurationError,
              "#{klass} declares `collapse: #{declared.inspect}` and cannot be enqueued with push_bulk: " \
              'a collapse policy decides per job, which would cost one Redis round trip per item where ' \
              'bulk enqueue costs one for the whole batch, and every returned jid would be nil. ' \
              'Push these jobs individually, or drop the policy on this worker.'
      end

      private

      # On whatever options hash the caller passed, so both the class-definition
      # door (the merged options, where a subclass adding `collapse:` to a
      # parent's `unique_for:` becomes visible) and the payload door (a per-call
      # `set(collapse:)` over a class-level `unique_for:`) are covered by the one
      # check. `unique_for: false` is the documented opt-out and reads as absent,
      # which is what {Wurk::Unique.coerce_ttl} already decides.
      def reject_unique!(options, declared)
        return unless Wurk::Unique.coerce_ttl(options['unique_for'])

        raise ConfigurationError,
              "#{options['class']} sets both `unique_for: #{options['unique_for'].inspect}` and " \
              "`collapse: #{declared.inspect}`. They are two answers to the same question and do not " \
              'compose: the lock drops the re-enqueue a debounce needs to extend its burst, and which ' \
              'one wins would depend on client middleware registration order. Keep one.'
      end

      def symbolized(declared)
        unless declared.is_a?(::Hash)
          raise ConfigurationError,
                "Job 'collapse' must be a Hash naming a policy, e.g. " \
                "`collapse: { policy: :debounce, wait: 5 }`: #{declared.inspect}"
        end

        declared.to_h { |key, value| [key.to_sym, value] }
      end

      # Symbol or String, because a payload that has crossed Redis carries the
      # JSON spelling of whatever the class declared.
      def policy_name!(raw, declared)
        name = raw.to_sym if raw.respond_to?(:to_sym)
        return name if PARAMS.key?(name)

        raise ConfigurationError,
              "unknown collapse policy #{raw.inspect} in #{declared.inspect}; " \
              "valid policies are #{PARAMS.keys.map(&:inspect).join(' and ')}"
      end

      # Missing and unknown are reported together: `{ policy: :debounce, slot: 5 }`
      # is one mistake — `slot:` written where `wait:` belongs — and naming only
      # half of it sends the reader round twice.
      def check_keys!(name, params, declared)
        spec = PARAMS.fetch(name)
        faults = key_faults(spec, params.keys)
        return if faults.empty?

        raise ConfigurationError,
              "collapse policy #{name.inspect} in #{declared.inspect} #{faults.join(' and ')}; " \
              "it takes #{list(spec[:required] + spec[:optional])}"
      end

      def key_faults(spec, given)
        missing = spec[:required] - given
        unknown = given - spec[:required] - spec[:optional]
        faults = []
        faults << "requires #{list(missing)}" unless missing.empty?
        faults << "does not take #{list(unknown)}" unless unknown.empty?
        faults
      end

      def list(keys) = keys.map(&:inspect).join(', ')

      def check_seconds!(name, params, declared)
        whole = PARAMS.fetch(name)[:whole]
        params.each do |key, value|
          next if usable_seconds?(value, whole)

          raise ConfigurationError,
                "collapse #{name} #{key} must be a positive #{'whole ' if whole}number of " \
                "seconds: #{declared.inspect}"
        end
      end

      def usable_seconds?(value, whole)
        return false unless Wurk::JobUtil.positive_seconds?(value)

        !whole || (value.to_f % 1).zero?
      end

      # A cap below the quiet period fires every burst at `first + max_wait`
      # regardless of traffic, which is a throttle wearing a debounce's name.
      # {Wurk::Debounce} refuses it too; refusing it here is what makes the
      # refusal land at the class rather than at the first push.
      def reject_short_cap!(params, declared)
        cap = params[:max_wait]
        return if cap.nil? || cap.to_f >= params[:wait].to_f

        raise ConfigurationError,
              "collapse debounce max_wait (#{cap}) must be at least wait (#{params[:wait]}): #{declared.inspect}"
      end
    end

    # Client middleware — the collapse decision, taken once every other
    # middleware has had the payload.
    #
    # Prepended, and it decides *after* its yield. Both halves are load-bearing.
    # Nothing in the client chain writes to Redis — {Wurk::Client#push} does that
    # only once `invoke_chain` has handed a payload back — so a middleware is
    # free to run the rest of the chain and then halt the push by returning nil.
    # Deciding on the way out means the payload {Wurk::Debounce} stores in
    # `schedule` carries everything the enrichers stamped on it (`bid`, `locale`,
    # `cattr`, `traceparent`), so a debounced job really is the scheduled job a
    # `perform_in` would have written rather than a stripped-down cousin. Sitting
    # outermost is what keeps that true for the middleware a host installs later
    # at boot: `Unique.enable!`, `Encryption.enable!` and `Telemetry.install!`
    # all `add`, which appends *inside* this one.
    class ClientMiddleware
      include Wurk::Middleware::ClientMiddleware
      # For #verify_json alone. Client walks the args of what the chain hands
      # back (client.rb:156) — after this middleware has already halted it — so
      # the one payload Client never verifies is the one written from in here.
      include Wurk::JobUtil

      def call(_worker, job, _queue, redis_pool)
        # One Hash lookup for a job that declares nothing, which is every job in
        # an app that uses neither policy.
        return yield if job[Wurk::Collapse::OPTION].nil?

        policy = Wurk::Collapse.policy_for(job)
        payload = yield
        return nil if payload.nil?

        decide(policy, payload, redis_pool)
      end

      private

      def decide(policy, job, pool)
        reject_incompatible!(job, policy)
        return collapse(job, policy, pool) if policy.name == :debounce

        admit(job, policy, pool)
      end

      # Returns nil unconditionally: the job is already in `schedule`, and the
      # jid it is under is not the caller's to act on (see the module docs).
      def collapse(job, policy, pool)
        verify_json(job)
        outcome = Wurk::Debounce.schedule(job, pool: pool, **policy.params)
        log_collapsed(job, outcome)
        nil
      end

      # The payload on admission, so the push continues exactly as it would with
      # no policy at all; nil on a drop, halting it.
      def admit(job, policy, pool)
        outcome = Wurk::Throttle.admit(job, pool: pool, **policy.params)
        return job if outcome.admitted?

        log_dropped(job, outcome)
        nil
      end

      def reject_incompatible!(job, policy)
        reject_encrypted!(job)
        return unless policy.name == :debounce

        reject_batched!(job)
        reject_scheduled!(job)
      end

      # Encryption rewrites the last argument with a fresh IV on every push, so
      # the identity digest — {Wurk::Unique}'s, shared by all three policies —
      # never repeats and nothing ever collapses. Same failure and same answer as
      # `Unique::ClientMiddleware#reject_encrypted!`: fail the push, because
      # silence here is a policy that is configured, running, and doing nothing.
      def reject_encrypted!(job)
        return unless job['encrypt']
        return unless defined?(Wurk::Encryption) && Wurk::Encryption.enabled?

        raise Wurk::Collapse::ConfigurationError,
              "#{job['class']} sets both `collapse:` and `encrypt: true`, which cannot work: " \
              'encryption rewrites the last argument with a fresh IV on every push, so the ' \
              'identity digest never repeats and no two jobs ever collapse. Drop one of the two.'
      end

      # A debounced job is written straight into `schedule` by the Lua script,
      # which is the write BATCH_SCHEDULE would otherwise have made — so the
      # batch never counts a job that will nevertheless run and decrement its
      # `pending` on the way out, and the batch completes early or goes negative.
      # A throttled one is safe either way: admitted, it takes the ordinary
      # batched path; dropped, it is simply not in the batch, exactly as a
      # duplicate dropped by {Wurk::Unique} is not.
      def reject_batched!(job)
        return unless job['bid']

        raise Wurk::Collapse::ConfigurationError,
              "#{job['class']} declares a debounce policy and cannot be enqueued inside a batch: " \
              'the collapsed job is written straight to `schedule`, so the batch would never count ' \
              'a job that still decrements its pending counter when it runs.'
      end

      # `at` is not the caller's to set on a debounced job: the policy owns the
      # fire time, and JobUtil.scheduled_member strips `at` off the stored member,
      # so a `perform_in(1.hour)` here would quietly fire in `wait` seconds.
      def reject_scheduled!(job)
        return unless job['at']

        raise Wurk::Collapse::ConfigurationError,
              "#{job['class']} declares a debounce policy, which owns the fire time, so it cannot " \
              'also be scheduled with perform_in/perform_at/set(wait:). Use `wait:` and `max_wait:`.'
      end

      # Info, matching Unique's dropped-duplicate line: something the caller
      # asked for did not happen, and the incumbent's jid is the fact a loser
      # cannot recover for itself afterwards. Unguarded: Configuration#logger
      # memoizes a default rather than ever handing back nil.
      def log_dropped(job, outcome)
        Wurk.logger.info do
          "Wurk::Collapse: throttled #{job['class']} dropped " \
            "(jid=#{job['jid']} blocked by jid=#{outcome.jid})"
        end
      end

      # Debug, unlike the drop above. A burst is many pushes by construction and
      # every one of them lands here, so info would be a log line per enqueue at
      # exactly the rate this policy exists to absorb.
      def log_collapsed(job, outcome)
        return unless outcome.replaced?

        Wurk.logger.debug do
          "Wurk::Collapse: debounced #{job['class']} replaced the pending job " \
            "(jid=#{job['jid']} fires at #{outcome.at})"
        end
      end
    end
  end
end
