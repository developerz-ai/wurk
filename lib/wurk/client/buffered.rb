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
    # A failed push opens a circuit for that Redis: later pushes buffer without
    # touching the socket, so one caller pays the connection backoff and the rest
    # do not. The Drainer thread, started on the first failure if none is running,
    # is what probes the server and closes the circuit.
    #
    # One buffer serves every pool, so each entry remembers the Redis it was
    # headed for (its {Origin}) and is only ever replayed there: a sharded app
    # pushing through `Client.via(shard_a)` must not have its outage backlog
    # land on shard B because B's producer happened to push next.
    #
    # Spec: docs/target/sidekiq-pro.md §5.
    module Buffered # rubocop:disable Metrics/ModuleLength
      DEFAULT_BUFFER_CAP = 1_000
      DRAINING_KEY = :wurk_reliable_push_draining
      UNBUFFERED_KEY = :wurk_reliable_push_unbuffered

      # A clean exit tries to deliver what is still in memory, but never holds the
      # process up for longer than this: a hung Redis would otherwise stall shutdown.
      EXIT_FLUSH_SECONDS = 5
      # Paces flush's retries as well as its checks, so a server that keeps refusing
      # gets a few attempts in that window and not hundreds of reports.
      FLUSH_POLL = 0.25

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

      # `bytes` is the payload's JSON size, what `reliable_push_buffer_bytes`
      # counts.
      Entry = Struct.new(:payload, :origin, :bytes)

      # Where a buffered payload has to be replayed. What must NOT be captured
      # is a pool object the config hands out: `reset_redis_pools!` — every
      # fork, every embedded teardown — disconnects it and drops it for a
      # lazily rebuilt one, and ConnectionPool#shutdown is terminal, so a
      # pinned instance replays into dead sockets for the rest of the process's
      # life. For such a pool the config (a Configuration or a Capsule, which
      # survives the rebuild) is kept and asked again at replay time. A pool
      # the config does not own — `Client.new(pool:)`, `Client.via(pool)` — is
      # a second Redis nothing else can produce, so that one stays pinned,
      # stale or not: replaying it anywhere else writes to the wrong server.
      Origin = Struct.new(:config, :pool) do
        def self.for(client)
          pool = client.send(:pool)
          config = client.instance_variable_get(:@config)
          owned = config.respond_to?(:redis_pool) && config.redis_pool.equal?(pool)
          owned ? new(config, nil) : new(nil, pool)
        end

        def resolve
          config ? config.redis_pool : pool
        end
      end

      # Which Redis servers are refusing connections, by pool identity. An entry
      # exists only while its circuit is open, so a rebuilt pool leaves nothing behind.
      class Circuit
        # A circuit closes itself after this long, so a dead drainer costs a caller
        # one attempt per window instead of buffering forever. A failed probe renews it.
        OPEN_SECONDS = 30.0

        def initialize
          @lock = Mutex.new
          @open_until = {}.compare_by_identity
        end

        def open?(pool)
          return false if @open_until.empty?

          @lock.synchronize do
            deadline = @open_until[pool]
            next false unless deadline
            next true if monotonic < deadline

            @open_until.delete(pool)
            false
          end
        end

        def trip(pool)
          @lock.synchronize { @open_until[pool] = monotonic + OPEN_SECONDS }
        end

        def close(pool)
          @lock.synchronize { @open_until.delete(pool) }
        end

        def any_open?
          !@open_until.empty?
        end

        # For a circuit with nothing buffered behind it (a batched push tripped it,
        # or `:raise` overflow kept the buffer empty): no replay exists to prove the
        # server is back. Any answer means reachable, and an error such as LOADING
        # belongs to the next real push to report, not to the circuit.
        def ping_all(except:)
          @lock.synchronize { @open_until.keys }.each { |pool| ping(pool) unless except.any? { |o| o.equal?(pool) } }
        end

        private

        def ping(pool)
          pool.with { |conn| conn.call('PING') }
          close(pool)
        rescue RedisClient::ConnectionError, ConnectionPool::TimeoutError
          trip(pool)
        rescue RedisClient::CommandError
          close(pool)
        end

        def monotonic
          ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        end
      end

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
      @replaying     = 0
      @buffer_bytes  = 0
      @circuit       = Circuit.new

      # Process that owns the state above; a mismatch means we're running in a
      # fork and the inherited copy has to go.
      @owner_pid = ::Process.pid

      class << self
        # Idempotent. Prepends the wrapper module into Wurk::Client so push /
        # push_bulk / push_prepared drain the buffer before each call and raw_push catches
        # connection errors. Safe to call from multiple threads.
        def install!
          install_mutex.synchronize do
            return if @installed

            Wurk::Client.prepend(InstanceMethods)
            @installed = true
            at_exit { Buffered.flush }
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

        # Optional second cap, in bytes of payload JSON (Wurk-only; nil, the
        # default, leaves only the entry cap). The entry cap alone lets a burst
        # of large payloads hold `cap x payload size` in a web process for the
        # whole outage. Over either cap the overflow mode applies; a payload
        # larger than this cap on its own never fits, so it is the one dropped
        # (or raised).
        attr_reader :buffer_bytes_cap

        def buffer_bytes_cap=(value)
          unless value.nil? || (value.is_a?(Integer) && value.positive?)
            raise ArgumentError, 'reliable_push_buffer_bytes must be nil or a positive Integer'
          end

          @buffer_bytes_cap = value
        end

        def buffer_size
          buffer_mutex.synchronize { buffer.size }
        end

        def buffer_bytes
          buffer_mutex.synchronize { @buffer_bytes }
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
            @buffer_bytes = 0
            @buffer_cap = nil
            @buffer_bytes_cap = nil
            @overflow_mode = nil
            @replaying = 0
          end
          @circuit = Circuit.new
          @drops = DropLog.new
          # Stop before dropping: an unstopped drainer thread would otherwise
          # tick on forever, unreachable, leaking the thread.
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
        # fills itself.
        #
        # Deliberately unsynchronized: the child has exactly one thread here,
        # and waiting on the very mutex being replaced is what would hang it.
        def reset_after_fork! # rubocop:disable Naming/PredicateMethod
          return false if @owner_pid == ::Process.pid

          @owner_pid             = ::Process.pid
          @install_mutex         = Mutex.new
          @buffer_mutex          = Mutex.new
          @buffer                = []
          @buffer_bytes          = 0
          @replaying             = 0
          @circuit               = Circuit.new
          @drops                 = DropLog.new
          interval               = @drainer&.interval unless @implicit_drainer
          @implicit_drainer      = false
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
        # `client` is the one whose push failed; every payload is tagged with
        # the Redis that client was writing to (see Origin).
        def enbuffer(payloads, client:)
          entries = entries_for(payloads, client)
          caps = [buffer_cap, buffer_bytes_cap]
          mode = overflow_mode
          undelivered = buffer_mutex.synchronize do
            mode == :raise ? append_within_capacity(entries, *caps) : append_dropping_oldest(entries, *caps)
          end

          raise Overflow, undelivered.map(&:payload) unless undelivered.empty?
        ensure
          drops.report(*caps)
        end

        private

        def entries_for(payloads, client)
          origin = Origin.for(client)
          payloads.map { |payload| Entry.new(payload, origin, Wurk.dump_json(payload).bytesize) }
        end

        # Both append helpers run with buffer_mutex held and return the entries
        # they could not take.

        def append_dropping_oldest(entries, cap, bytes_cap)
          entries.each do |entry|
            next drops.record(entry.payload) if bytes_cap && entry.bytes > bytes_cap

            drops.record(take_oldest.payload) until fits?(entry, cap, bytes_cap)
            push_entry(entry)
          end
          NOTHING_UNDELIVERED
        end

        # The split has to be decided before any mutation: raising from inside
        # the append loop leaves every payload after the rejected one neither
        # buffered, nor enqueued, nor attached to the exception. `room` goes
        # negative when the cap was lowered after the buffer filled — clamped,
        # so an over-full buffer rejects the whole call instead of raising on
        # `first`/`drop`.
        def append_within_capacity(entries, cap, bytes_cap)
          room = (cap - buffer.size).clamp(0, entries.size)
          room = bytes_room(entries.first(room), bytes_cap) if bytes_cap
          entries.first(room).each { |entry| push_entry(entry) }
          room == entries.size ? NOTHING_UNDELIVERED : entries.drop(room)
        end

        # How many of `entries`, in order, fit under the byte cap.
        def bytes_room(entries, bytes_cap)
          total = @buffer_bytes
          entries.take_while { |entry| (total += entry.bytes) <= bytes_cap }.size
        end

        def fits?(entry, cap, bytes_cap)
          buffer.size < cap && (bytes_cap.nil? || @buffer_bytes + entry.bytes <= bytes_cap)
        end

        # The three buffer mutations, each under buffer_mutex, each keeping the
        # byte total (`@buffer_bytes`) in step.
        def push_entry(entry)
          @buffer_bytes += entry.bytes
          buffer << entry
        end

        def take_oldest
          remove_at(0)
        end

        def remove_at(index)
          entry = buffer.delete_at(index)
          @buffer_bytes -= entry.bytes
          entry
        end

        public

        # Replay, through `raw_push` on `client`, the buffered payloads headed
        # for the Redis that client writes to — oldest first; entries for any
        # other Redis are left in place, so a push to a healthy shard neither
        # misroutes nor waits on a dead one's backlog. Stops on the first
        # transient failure (ConnectionError past the pool's own retries, or a
        # starved checkout) and puts that payload back at the head, so the next
        # push retries it first. Emits statsd `jobs.recovered.push` per drained
        # payload, plus the `jobs.enqueued` the buffering push deliberately did
        # not emit — the replay is where the job actually reaches Redis, so a
        # buffered-then-drained job counts once as enqueued and once as
        # recovered.
        #
        # Skipped outright while the circuit is open, unless this is the probe.
        def drain!(client, probe: false)
          target = client.send(:pool)
          return 0 if !probe && circuit.open?(target)
          return 0 if buffer_mutex.synchronize { buffer.empty? }

          drained = replay_all(client, target)
          drops.end_burst if drained.positive?
          drained
        end

        # Pushes inside the block reach Redis or raise. For a caller that goes on to
        # delete its own copy of the job once push returns, which must not count
        # memory as delivered: a crash would then lose the only copy.
        def unbuffered
          previous = Thread.current[UNBUFFERED_KEY]
          Thread.current[UNBUFFERED_KEY] = true
          yield
        ensure
          Thread.current[UNBUFFERED_KEY] = previous
        end

        def unbuffered?
          Thread.current[UNBUFFERED_KEY] == true
        end

        # Replays whatever is still buffered, whichever circuit it is behind, for up
        # to `timeout`. Returns how many jobs are left. Runs on a clean exit; a
        # Launcher or host shutting down earlier can call it too. Forked children
        # inherit the at_exit hook, but start with an empty buffer of their own.
        def flush(timeout: EXIT_FLUSH_SECONDS)
          return 0 if undelivered_count.zero?

          retry_until_delivered(flush_clock + timeout)
          undelivered_count.tap { |left| report_undelivered(left) if left.positive? }
        end

        def trip!(pool)
          circuit.trip(pool)
          ensure_drainer
        end

        # The background drainer's pass: every origin in the buffer, each
        # through a client of its own, so one Redis still down does not hold
        # back another that has recovered. Returns the total replayed; the
        # first non-transient error is re-raised after every origin had its turn.
        def drain_all!
          failure = nil
          pools = buffered_pools
          drained = pools.sum do |pool|
            drain!(Wurk::Client.new(pool: pool), probe: true)
          rescue StandardError => e
            failure ||= e
            0
          end
          circuit.ping_all(except: pools)
          raise failure if failure

          drained
        end

        # Internal — visible for tests. Treat as private. Holds Entry structs.
        def buffer
          @buffer ||= []
        end

        attr_reader :drops, :circuit

        # Start a background drain thread that wakes every `interval`
        # seconds and tries to flush the buffer. Idempotent — replaces
        # any prior drainer with one at the new interval. Issue #19
        # requirement: "Background drain thread flushes on reconnect" —
        # handles the case where push activity stops mid-outage so the
        # passive (drain-on-next-push) path never fires.
        def start_drainer!(interval: Drainer::DEFAULT_INTERVAL)
          install_mutex.synchronize do
            @drainer&.stop
            @implicit_drainer = false
            @drainer = Drainer.new(interval: interval)
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

        # A replay holds its entry outside the buffer until it lands or goes back, so
        # an empty buffer alone does not mean every job reached Redis.
        def undelivered_count
          buffer_mutex.synchronize { buffer.size + @replaying }
        end

        def retry_until_delivered(deadline)
          worker = nil
          until undelivered_count.zero? || flush_clock >= deadline
            worker = start_flush_attempt unless worker&.alive? || buffer_size.zero?
            sleep(FLUSH_POLL)
          end
        end

        def flush_clock
          ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        end

        def start_flush_attempt
          Thread.new do
            drain_all!
          rescue StandardError => e
            Wurk.configuration.handle_exception(e, { context: 'reliable_push flush' })
          end
        end

        def report_undelivered(left)
          Wurk.configuration.logger.error do
            "reliable_push: #{left} buffered job(s) could not reach Redis before exit and are lost"
          end
        rescue StandardError
          nil
        end

        # Leaves the circuit open on the first failed replay and closed once the
        # backlog for this Redis has run out.
        def replay_all(client, target)
          drained = 0
          while (entry = take_next(target))
            unless replay(client, entry)
              trip!(target)
              return drained
            end
            drained += 1
          end
          circuit.close(target)
          drained
        end

        # An app's own drainer keeps its interval; only the absence of one makes
        # this implicit, which is what stops `reset_after_fork!` re-arming it in
        # children that never pushed.
        def ensure_drainer
          install_mutex.synchronize do
            next if @drainer&.running?

            @implicit_drainer = @drainer.nil?
            @drainer ||= Drainer.new
            @drainer.start
          end
        end

        # The oldest entry bound for `target`, removed from the buffer.
        def take_next(target)
          buffer_mutex.synchronize do
            index = buffer.index { |entry| entry.origin.resolve.equal?(target) }
            next unless index

            @replaying += 1
            remove_at(index)
          end
        end

        def replay_settled
          buffer_mutex.synchronize { @replaying = [@replaying - 1, 0].max }
        end

        def buffered_pools
          buffer_mutex.synchronize { buffer.map { |entry| entry.origin.resolve } }.uniq(&:object_id)
        end

        # The entry once it is in Redis, nil when it went back to the buffer.
        # Same-origin order is all that matters (other entries go to another
        # server), so a payload that could not be replayed goes back at the
        # absolute head: ahead of every later entry for its own Redis.
        def replay(client, entry)
          begin
            replayed = attempt_replay(client, entry.payload)
          rescue StandardError
            # Non-connection failures (OOM, LOADING, READONLY…) must not drop
            # the taken payload — restore it before propagating, or a
            # recovering-but-not-ready Redis silently eats one buffered job per
            # drain tick. Redis answered, so the circuit closes and pushes go back
            # to surfacing the refusal to their callers.
            restore(entry)
            circuit.close(client.send(:pool))
            raise
          end
          unless replayed
            restore(entry)
            return
          end

          client.send(:emit_enqueued, [entry.payload])
          Wurk::Metrics::Statsd.increment('jobs.recovered.push')
          entry
        ensure
          replay_settled
        end

        def restore(entry)
          buffer_mutex.synchronize do
            @buffer_bytes += entry.bytes
            buffer.unshift(entry)
          end
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

      # The jobs `:drop_oldest` evicts. A drop is a job the caller was told was
      # enqueued and that will now never run, so it must never be silent. One
      # ERROR per burst — the first drop since a replay last reached Redis —
      # because an outage that outlasts the cap drops on every push, and a line
      # per job would bury the one that says what happened. Every drop still
      # counts, as the statsd `jobs.dropped.push` counter.
      #
      # #record runs under the buffer's mutex; #report runs after it is
      # released, so neither the log write nor statsd holds up other pushes.
      class DropLog
        def initialize
          @lock = Mutex.new
          @pending = []
          @burst = false
        end

        def record(payload)
          @lock.synchronize { @pending << payload }
        end

        def report(cap, bytes_cap = nil)
          dropped, announce = @lock.synchronize do
            next [nil, false] if @pending.empty?

            taken = @pending
            @pending = []
            first = !@burst
            @burst = true
            [taken, first]
          end
          return unless dropped

          log(dropped.first, cap, bytes_cap) if announce
          dropped.size.times { count_drop }
        end

        # A replay reached Redis, so the outage that filled the buffer is over:
        # the next overflow is a new incident and gets its own ERROR.
        def end_burst
          @lock.synchronize { @burst = false }
        end

        private

        # Runs in Buffered.enbuffer's `ensure`: anything raised here would
        # replace the push's own result (its return, or the Overflow it is
        # raising), so the metric is strictly best-effort.
        def count_drop
          Wurk::Metrics::Statsd.increment('jobs.dropped.push')
        rescue StandardError
          nil
        end

        def log(first, cap, bytes_cap)
          Wurk.configuration.logger.error do
            "reliable_push buffer full (cap=#{cap}#{", bytes=#{bytes_cap}" if bytes_cap}): " \
              'dropping the oldest buffered jobs to make room — ' \
              "#{first['class']} jid=#{first['jid']} is the first of this burst and will never run. " \
              'Further drops are counted in statsd jobs.dropped.push until Redis takes a replay. Raise ' \
              '`Wurk::Client.reliable_push_buffer` (or `reliable_push_buffer_bytes`), or set ' \
              '`reliable_push_overflow = :raise` to handle overflow yourself.'
          end
        rescue StandardError
          nil
        end
      end

      # Eager for the reason the mutexes are: a lazy `||=` could hand two
      # racing first pushes different logs.
      @drops = DropLog.new

      # Background drain thread and the circuit's only prober. Started on the first
      # failed push if the app did not start one; wakes every `interval` seconds and
      # runs `Buffered.drain_all!`, which costs no Redis round trip while the buffer
      # is empty and no circuit is open. drain! already short-circuits on the first
      # transient failure, so a still-down Redis just leaves its entries alone
      # for this tick — no exponential backoff or explicit "reconnect
      # detection" needed; the inner connection retry already lives inside
      # `client.raw_push`.
      class Drainer
        DEFAULT_INTERVAL = 2.0
        STOP_JOIN_TIMEOUT = 5.0
        # While a circuit is open, pushes are only in memory, so finding out that
        # Redis is back quickly matters more than the interval an idle drainer keeps.
        PROBE_PAUSE = 0.25

        # Read by `Buffered.reset_after_fork!` off the *inherited* drainer, to
        # rebuild an equivalent one in the child without touching its lock.
        attr_reader :interval

        def initialize(interval: DEFAULT_INTERVAL)
          unless interval.is_a?(Numeric) && interval.positive?
            raise ArgumentError, 'interval must be a positive Numeric'
          end

          @interval = interval
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

            tick
          end
        end

        # A raise must not end the thread — the next tick retries — but it is
        # reported: a transient outage never gets here (drain! absorbs it), so
        # whatever does is something an operator needs to see.
        def tick
          Buffered.drain_all!
        rescue StandardError => e
          report(e)
        end

        def report(error)
          Wurk.configuration.handle_exception(error, { context: 'reliable_push drainer' })
        rescue StandardError
          nil
        end

        # Mutex+ConditionVariable lets `stop` wake the thread immediately
        # instead of waiting up to `interval` seconds for sleep to return.
        def wait_interval
          pause = Buffered.circuit.any_open? ? [@interval, PROBE_PAUSE].min : @interval
          @lock.synchronize { @wake.wait(@lock, pause) unless @done }
        end
      end

      # Wraps Wurk::Client. push / push_bulk drain the buffer first;
      # raw_push catches transient failures — RedisClient::ConnectionError
      # past RedisPool's own retries, or a starved checkout
      # (ConnectionPool::TimeoutError) — and buffers non-batched payloads.
      module InstanceMethods
        def push(item)
          Buffered.drain!(self) unless Buffered.unbuffered?
          super
        end

        def push_bulk(items)
          Buffered.drain!(self) unless Buffered.unbuffered?
          super
        end

        def push_prepared(payloads)
          Buffered.drain!(self) unless Buffered.unbuffered?
          super
        end

        private

        # Opens the delivery ledger Client writes into. It lives here rather
        # than in Client because this rescue is its only reader: a Client
        # without reliable_push! never allocates it.
        def raw_push(payloads)
          return buffer_without_trying(payloads) if circuit_open_for?(payloads)

          Thread.current[DELIVERED_KEY] = []
          super
        rescue RedisClient::ConnectionError, ConnectionPool::TimeoutError
          raise if Thread.current[Buffered::DRAINING_KEY] || Buffered.unbuffered?

          buffer_undelivered(payloads)
        ensure
          Thread.current[DELIVERED_KEY] = nil
        end

        # Runs inside raw_push's rescue, so a bare `raise` is its connection error.
        # Client#push subtracts the returned payloads from the enqueued metric: they
        # are in the buffer, not in Redis. Whatever the group did deliver stays out
        # of the set and still counts.
        def buffer_undelivered(payloads)
          Buffered.trip!(pool)
          bidless, batched = undelivered(payloads).partition { |p| !p['bid'] }
          enbuffer_bidless(bidless, batched)
          raise unless batched.empty?

          bidless
        end

        # Batched payloads never buffer, so they still take the real attempt and
        # report its outcome to the caller.
        def circuit_open_for?(payloads)
          return false if Thread.current[Buffered::DRAINING_KEY] || Buffered.unbuffered?

          Buffered.circuit.open?(pool) && payloads.none? { |p| p['bid'] }
        end

        def buffer_without_trying(payloads)
          Buffered.enbuffer(payloads, client: self)
          payloads
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
      def reliable_push!
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

      def reliable_push_buffer_bytes
        Buffered.buffer_bytes_cap
      end

      def reliable_push_buffer_bytes=(value)
        Buffered.buffer_bytes_cap = value
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
