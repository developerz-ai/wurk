# frozen_string_literal: true

module Wurk
  class Client
    # Pro feature parity: in-process ring buffer that catches enqueue
    # failures during a Redis outage and replays them on the next push.
    # Activated globally — `Wurk::Client.reliable_push!`. Buffer is
    # per-process, in-memory only; crash = lost. Does NOT cover batch
    # creation or batch-context pushes (`bid` on payload): BATCH_PUSH has
    # atomic counter side-effects we can't safely replay.
    #
    # Spec: docs/target/sidekiq-pro.md §5.
    module Buffered
      DEFAULT_BUFFER_CAP = 1_000
      DRAINING_KEY = :wurk_reliable_push_draining

      # Overflow modes. `:drop_oldest` is the spec default (Sidekiq Pro §5
      # ring buffer). `:raise` lets callers decide what to do on backpressure
      # — Wurk extension surfaced for issue #19's "over-cap pushes raise so
      # callers can decide" requirement.
      OVERFLOW_MODES        = %i[drop_oldest raise].freeze
      DEFAULT_OVERFLOW_MODE = :drop_oldest

      # Raised when the cap would be exceeded under `overflow_mode == :raise`.
      # Inherits from RuntimeError so callers can rescue narrowly. Carries
      # EVERY payload the call failed to deliver — the tail that did not fit,
      # plus, on a mixed push, the batched payloads that never buffer — so a
      # caller can persist/log/forward the lot. `cause` is the connection error
      # that sent the push to the buffer in the first place.
      class Overflow < RuntimeError
        attr_reader :payloads

        def initialize(payloads)
          @payloads = payloads
          super("reliable_push buffer is full (cap=#{Buffered.buffer_cap}), " \
                "#{payloads.size} payload(s) undelivered")
        end
      end

      # Returned by the append helpers when everything fit.
      NOTHING_UNDELIVERED = [].freeze

      # Eagerly initialized: `||=` inside an accessor is not atomic — two
      # threads racing first-touch could end up holding distinct Mutex
      # instances and lose all synchronization on the shared buffer.
      #
      # Module ivars rather than constants so `reset_after_fork!` can replace
      # them outright. MRI abandons a mutex whose owner thread didn't survive
      # the fork (rb_thread_atfork), but that's an implementation detail rather
      # than a documented guarantee, and it does NOT cover a fork taken from
      # inside either critical section — there the child inherits the lock
      # still owned, and its first `Client#push` (which drains, so it
      # synchronizes, before pushing) blocks forever. Two allocations per fork
      # buys immunity from both.
      @install_mutex = Mutex.new
      @buffer_mutex  = Mutex.new

      # Process that owns the state above; a mismatch means we're running in a
      # fork and the inherited copy has to go.
      @owner_pid = ::Process.pid

      class << self
        attr_accessor :buffer_client_factory

        # Idempotent. Prepends the wrapper module into Wurk::Client so push /
        # push_bulk drain the buffer before each call and raw_push catches
        # connection errors. Safe to call from multiple threads.
        def install!
          install_mutex.synchronize do
            return if @installed

            Wurk::Client.prepend(InstanceMethods)
            @installed = true
          end
        end

        def installed?
          @installed == true
        end

        def buffer_cap
          @buffer_cap ||= DEFAULT_BUFFER_CAP
        end

        def buffer_cap=(value)
          unless value.is_a?(Integer) && value.positive?
            raise ArgumentError, 'reliable_push_buffer must be a positive Integer'
          end

          @buffer_cap = value
        end

        def buffer_size
          buffer_mutex.synchronize { buffer.size }
        end

        def overflow_mode
          @overflow_mode ||= DEFAULT_OVERFLOW_MODE
        end

        def overflow_mode=(mode)
          begin
            mode = mode.to_sym
          rescue NoMethodError, TypeError
            raise ArgumentError, "overflow_mode must be one of #{OVERFLOW_MODES.inspect}"
          end

          unless OVERFLOW_MODES.include?(mode)
            raise ArgumentError, "overflow_mode must be one of #{OVERFLOW_MODES.inspect}"
          end

          @overflow_mode = mode
        end

        def reset!
          buffer_mutex.synchronize do
            @buffer = []
            @buffer_cap = nil
            @overflow_mode = nil
            @buffer_client_factory = nil
          end
          # Stop before dropping: an unstopped drainer thread survives with
          # its factory nil'd out from under it and ticks forever against
          # nothing, leaking the thread and everything its closure retains.
          install_mutex.synchronize do
            @drainer&.stop
            @drainer = nil
          end
        end

        # Fork hook, called from the `Process._fork` prepend below and from
        # `Swarm::ChildBoot#reconnect_after_fork`. Whichever runs first wins
        # and returns true; the pid guard makes the other a no-op returning
        # false, so a caller can tell which one rebuilt the state.
        #
        # A child inherits a copy of every ivar here: the buffered payloads,
        # the Drainer (whose thread did not survive the fork), and both mutexes
        # (see their definition for why replacing them matters).
        #
        # The child DROPS its inherited payloads rather than replaying them:
        # the parent still holds the same buffer and replays it on its own next
        # push, so a child that also drained would enqueue every buffered job
        # once per fork — `(children + 1) x N` duplicates. Only the parent
        # replays.
        #
        # `@drainer` is dropped, never `stop`ped — its `@lock` carries the same
        # inherited-mutex hazard. A parent-configured drainer is replaced by an
        # equivalent fresh one so an opted-in child keeps flushing the buffer it
        # fills itself; the captured client factory goes with it, since it
        # closes over the parent's pre-fork Redis pool.
        #
        # Deliberately unsynchronized: the child has exactly one thread here,
        # and waiting on the very mutex being replaced is what would hang it.
        def reset_after_fork! # rubocop:disable Naming/PredicateMethod
          return false if @owner_pid == ::Process.pid

          @owner_pid             = ::Process.pid
          @install_mutex         = Mutex.new
          @buffer_mutex          = Mutex.new
          @buffer                = []
          @buffer_client_factory = nil
          interval               = @drainer&.interval
          @drainer               = nil
          start_drainer!(interval: interval) if interval
          true
        end

        # Append payloads to the buffer. Behavior on cap exhaustion depends
        # on `overflow_mode`:
        #   * :drop_oldest (default, spec) — ring buffer, oldest evicted.
        #   * :raise                       — fills the remaining capacity, then
        #                                    raises one Overflow carrying every
        #                                    payload that did not fit.
        # Drops batched payloads — caller is expected to re-raise for those.
        # If client is provided, captures its pool for drainer to use by default.
        def enbuffer(payloads, client: nil)
          capture_pool_from_client(client)

          cap  = buffer_cap
          mode = overflow_mode
          undelivered = buffer_mutex.synchronize do
            mode == :raise ? append_within_capacity(payloads, cap) : append_dropping_oldest(payloads, cap)
          end

          raise Overflow, undelivered unless undelivered.empty?
        end

        private

        # Remember how the buffering client reaches Redis, so the drainer
        # replays into the same server it was pushed to unless explicitly
        # overridden.
        def capture_pool_from_client(client)
          return unless client && !buffer_client_factory

          pool = client.instance_variable_get(:@redis_pool)
          # A nil capture must not install a factory: it would pin the drainer
          # to the DEFAULT pool forever (the `!buffer_client_factory` guard
          # blocks any later, correct capture) — wrong Redis for jobs pushed
          # through an explicit-pool client. A pool-less client already resolves
          # its config at push time, and so does the fallback factory.
          return unless pool

          resolver = pool_resolver(client, pool)
          self.buffer_client_factory = -> { Wurk::Client.new(pool: resolver.call) }
        end

        # What must NOT be captured is the pool object. `reset_redis_pools!` —
        # every fork, every embedded teardown — disconnects a pool and drops it
        # for a lazily rebuilt one, and ConnectionPool#shutdown is terminal, so
        # a pinned instance leaves the drainer replaying into dead sockets for
        # the rest of the process's life. The config (a Configuration or a
        # Capsule) is what survives that rebuild, so ask it again at drain time
        # whenever the client's pool is the one it hands out. A pool the config
        # does not own is a second Redis nothing else can produce — that one
        # stays pinned, stale or not, because replaying it anywhere else writes
        # to the wrong server.
        def pool_resolver(client, pool)
          config = client.instance_variable_get(:@config)
          config_owns = config.respond_to?(:redis_pool) && config.redis_pool.equal?(pool)
          config_owns ? -> { config.redis_pool } : -> { pool }
        end

        # Both append helpers run with buffer_mutex held and return the payloads
        # they could not take.

        def append_dropping_oldest(payloads, cap)
          payloads.each do |p|
            buffer.shift if buffer.size >= cap
            buffer << p
          end
          NOTHING_UNDELIVERED
        end

        # The split has to be decided before any mutation: raising from inside
        # the append loop leaves every payload after the rejected one neither
        # buffered, nor enqueued, nor attached to the exception. `room` goes
        # negative when the cap was lowered after the buffer filled — clamped,
        # so an over-full buffer rejects the whole call instead of raising on
        # `first`/`drop`.
        def append_within_capacity(payloads, cap)
          room = (cap - buffer.size).clamp(0, payloads.size)
          if room == payloads.size
            buffer.concat(payloads)
            return NOTHING_UNDELIVERED
          end

          buffer.concat(payloads.first(room))
          payloads.drop(room)
        end

        public

        # Drain payloads through `raw_push` on the given client. Stops on
        # the first transient failure (ConnectionError past the pool's own
        # retries, or a starved checkout), preserving order at the head of
        # the buffer so the next push retries the same payload. Emits statsd
        # `jobs.recovered.push` per drained payload, plus the `jobs.enqueued`
        # the buffering push deliberately did not emit — the replay is where
        # the job actually reaches Redis, so a buffered-then-drained job counts
        # once as enqueued and once as recovered.
        def drain!(client)
          drained = 0
          while (payload = pop_head)
            begin
              replayed = attempt_replay(client, payload)
            rescue StandardError
              # Non-connection failures (OOM, LOADING, READONLY…) must not
              # drop the popped payload — restore it before propagating, or
              # a recovering-but-not-ready Redis silently eats one buffered
              # job per drain tick.
              buffer_mutex.synchronize { buffer.unshift(payload) }
              raise
            end

            unless replayed
              buffer_mutex.synchronize { buffer.unshift(payload) }
              break
            end

            client.send(:emit_enqueued, [payload])
            Wurk::Metrics::Statsd.increment('jobs.recovered.push')
            drained += 1
          end
          drained
        end

        # Internal — visible for tests. Treat as private.
        def buffer
          @buffer ||= []
        end

        # Start a background drain thread that wakes every `interval`
        # seconds and tries to flush the buffer. Idempotent — replaces
        # any prior drainer with one at the new interval. Issue #19
        # requirement: "Background drain thread flushes on reconnect" —
        # handles the case where push activity stops mid-outage so the
        # passive (drain-on-next-push) path never fires.
        def start_drainer!(interval: Drainer::DEFAULT_INTERVAL, client_factory: nil)
          install_mutex.synchronize do
            @drainer&.stop
            factory = client_factory || buffer_client_factory || -> { Wurk::Client.new }
            @drainer = Drainer.new(interval: interval, client_factory: factory)
            @drainer.start
          end
        end

        def stop_drainer!
          install_mutex.synchronize do
            @drainer&.stop
            @drainer = nil
          end
        end

        def drainer_running?
          install_mutex.synchronize { @drainer&.running? == true }
        end

        private

        attr_reader :install_mutex, :buffer_mutex

        def pop_head
          buffer_mutex.synchronize { buffer.shift }
        end

        # Drain marks the thread so our prepended raw_push re-raises the
        # transient error back here instead of swallowing it into the buffer
        # (which would spin forever).
        def attempt_replay(client, payload)
          Thread.current[DRAINING_KEY] = true
          client.send(:raw_push, [payload])
          true
        rescue RedisClient::ConnectionError, ConnectionPool::TimeoutError
          false
        ensure
          Thread.current[DRAINING_KEY] = false
        end
      end

      # Background drain thread. Wakes every `interval` seconds and tries
      # `Buffered.drain!` against a fresh Wurk::Client. drain! already
      # short-circuits on the first transient failure, so a still-down Redis
      # just leaves the buffer alone for this tick — no exponential
      # backoff or explicit "reconnect detection" needed; the inner
      # connection retry already lives inside `client.raw_push`.
      class Drainer
        DEFAULT_INTERVAL = 2.0
        STOP_JOIN_TIMEOUT = 5.0

        # Read by `Buffered.reset_after_fork!` off the *inherited* drainer, to
        # rebuild an equivalent one in the child without touching its lock.
        attr_reader :interval

        def initialize(interval: DEFAULT_INTERVAL, client_factory: -> { Wurk::Client.new })
          unless interval.is_a?(Numeric) && interval.positive?
            raise ArgumentError, 'interval must be a positive Numeric'
          end

          @interval = interval
          @client_factory = client_factory
          @done = false
          @thread = nil
          @wake = ConditionVariable.new
          @lock = Mutex.new
        end

        def start
          @lock.synchronize do
            return if @thread&.alive?

            @done = false
            @thread = Thread.new do
              Thread.current.name = 'wurk-reliable_push-drainer'
              run
            end
          end
        end

        def stop
          @lock.synchronize do
            @done = true
            @wake.broadcast
          end
          @thread&.join(STOP_JOIN_TIMEOUT)
          @thread = nil
        end

        def running?
          @thread&.alive? == true
        end

        private

        def run
          until @done
            wait_interval
            break if @done

            begin
              Buffered.drain!(@client_factory.call)
            rescue StandardError
              # Swallow — next tick retries. Don't let a transient blow up
              # the daemon thread.
            end
          end
        end

        # Mutex+ConditionVariable lets `stop` wake the thread immediately
        # instead of waiting up to `interval` seconds for sleep to return.
        def wait_interval
          @lock.synchronize { @wake.wait(@lock, @interval) unless @done }
        end
      end

      # Wraps Wurk::Client. push / push_bulk drain the buffer first;
      # raw_push catches transient failures — RedisClient::ConnectionError
      # past RedisPool's own retries, or a starved checkout
      # (ConnectionPool::TimeoutError) — and buffers non-batched payloads.
      module InstanceMethods
        def push(item)
          Buffered.drain!(self)
          super
        end

        def push_bulk(items)
          Buffered.drain!(self)
          super
        end

        private

        # Opens the delivery ledger Client writes into. It lives here rather
        # than in Client because this rescue is its only reader: a Client
        # without reliable_push! never allocates it.
        def raw_push(payloads)
          Thread.current[DELIVERED_KEY] = []
          super
        rescue RedisClient::ConnectionError, ConnectionPool::TimeoutError
          raise if Thread.current[Buffered::DRAINING_KEY]

          bidless, batched = undelivered(payloads).partition { |p| !p['bid'] }
          enbuffer_bidless(bidless, batched)
          raise unless batched.empty?

          # Client#push subtracts these from the enqueued metric: they are in
          # the buffer, not in Redis. Whatever the group did deliver stays out
          # of the set and still counts.
          bidless
        ensure
          Thread.current[DELIVERED_KEY] = nil
        end

        # The payloads this push is not known to have written. A push spanning
        # several queues, or one mixing plain and batched jobs, fails after
        # some of its groups already landed; buffering those would replay them
        # into duplicate jobs once the outage clears. The ledger holds the very
        # Hash objects Client just handed to Redis, hence the identity subtract.
        def undelivered(payloads)
          delivered = Thread.current[DELIVERED_KEY]
          return payloads if delivered.empty?

          reject_by_identity(payloads, delivered)
        end

        # Bare `raise` re-raises whatever `$!` holds: the connection error from
        # the caller's rescue, or the Overflow once we're inside this one.
        def enbuffer_bidless(bidless, batched)
          Buffered.enbuffer(bidless, client: self) if bidless.any?
        rescue Buffered::Overflow => e
          # An overflow pre-empts the caller's connection-error re-raise, which
          # would strand the batched payloads silently — they never buffer. One
          # exception, every payload that failed to get through; `cause` stays
          # the connection error rather than the folded-in Overflow.
          raise if batched.empty?

          raise Buffered::Overflow, e.payloads + batched, cause: e.cause
        end
      end

      # Ruby >= 3.1 routes every `fork` / `Process.fork` through
      # `Process._fork`, which is the only way to catch the forks Wurk never
      # sees: a Puma or Unicorn parent that preloaded the app — and may already
      # be holding buffered payloads — spawning its workers. Registered at
      # require time because `reliable_push!` can be installed after the fork
      # that copied the state. Guarded on the fork-less runtimes (JRuby), where
      # there is no `super` to call.
      module ForkHook
        def _fork
          pid = super
          Buffered.reset_after_fork! if pid.zero?
          pid
        end
      end
      ::Process.singleton_class.prepend(ForkHook) if ::Process.respond_to?(:_fork)
    end

    class << self
      # Activate reliable_push! mode globally. Idempotent — call from the
      # top level of an initializer (NOT inside Wurk.configure_*). Spec:
      # docs/target/sidekiq-pro.md §5.
      def reliable_push! # rubocop:disable Naming/PredicateMethod
        Buffered.install!
        true
      end

      def reliable_push?
        Buffered.installed?
      end

      def reliable_push_buffer
        Buffered.buffer_cap
      end

      def reliable_push_buffer=(value)
        Buffered.buffer_cap = value
      end

      def reliable_push_overflow
        Buffered.overflow_mode
      end

      def reliable_push_overflow=(mode)
        Buffered.overflow_mode = mode
      end

      # Start an opt-in background drainer thread. Implicitly enables
      # reliable_push! so callers don't have to chain the two. Idempotent;
      # calling again replaces the thread with one at the new interval.
      # Spec for reliable_push (sidekiq-pro.md §5) only requires drain on
      # next push — this is a Wurk extension for issue #19's "Background
      # drain thread flushes on reconnect" so producer-stopped-mid-outage
      # buffers don't sit idle until next push.
      def reliable_push_drainer(interval: Buffered::Drainer::DEFAULT_INTERVAL) # rubocop:disable Naming/PredicateMethod
        Buffered.install!
        Buffered.start_drainer!(interval: interval)
        true
      end

      def reliable_push_drainer_stop!
        Buffered.stop_drainer!
      end

      def reliable_push_drainer_running?
        Buffered.drainer_running?
      end
    end
  end
end
