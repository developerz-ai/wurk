# frozen_string_literal: true

require_relative '../web/enterprise'
require_relative 'page'
require_relative 'problem'
require_relative 'response'
require_relative 'roll_up'
require_relative 'serializers'
require_relative 'validation'

module Wurk
  module API
    # The swarm plane: how the fleet is laid out, what each process is doing
    # right now, and the two signals an operator sends it.
    #
    # Read-only against Redis structures that already exist — the `processes`
    # SET and its per-identity heartbeat HASHes, `<identity>:work`,
    # `dear-leader`, the limiter and cron registries. No new key, no new field
    # on the beat, and nothing here makes a process beat more often. A
    # monitoring client polling `GET /swarm` every few seconds must cost the
    # swarm nothing, so every route reads through the canonical inspectors
    # ({Wurk::ProcessSet}, {Wurk::WorkSet}, {Wurk::Cron::LoopSet},
    # Web::Enterprise::Limits) exactly as the dashboard does.
    #
    # One deliberate divergence from the dashboard: `ProcessSet.new(false)`
    # everywhere. The default constructor also runs the SREM sweep for expired
    # identities, which is a write, rate-limited by a `SET NX EX` that is
    # itself a write. Every count reported here comes from `#each`, which
    # already skips identities whose `info` has expired, so the sweep would buy
    # no accuracy — only a Redis write on each poll of a plane that is supposed
    # to be free to watch. The dashboard keeps the sweep; an operator has it
    # open for minutes, not milliseconds.
    module Swarm
      # Signal targets. An identity is `<hostname>:<pid>:<nonce>`, so nothing
      # live can be named `all` and the sentinel needs no escaping.
      ALL = 'all'
      QUIET_SIGNAL = 'TSTP'
      STOP_SIGNAL = 'TERM'

      MAX_FILTER_LENGTH = 255

      # The two signals take :admin. Quieting the fleet stops it working
      # without enqueueing or deleting anything — the same reasoning that puts
      # queue pausing with the destructive routes rather than the listings.
      TABLE = [
        [:get, '/swarm', :read, :cluster],
        [:get, '/processes', :read, :index],
        [:get, '/processes/:identity', :read, :show],
        [:post, '/processes/:identity/quiet', :admin, :quiet],
        [:post, '/processes/:identity/stop', :admin, :stop],
        [:get, '/busy', :read, :busy],
        [:get, '/health', :read, :health],
        [:get, '/limiters', :read, :limiters],
        [:get, '/cron', :read, :cron]
      ].freeze

      module_function

      def draw(router)
        TABLE.each do |verb, pattern, scope, handler|
          router.public_send(verb, pattern, scope: scope) do |request|
            public_send(handler, request)
          rescue Validation::Invalid => e
            Problem.from(e, instance: request.path)
          end
        end
      end

      def cluster(_request)
        set = ::Wurk::ProcessSet.new(false)
        Response.json(200, RollUp.cluster(set.to_a, leader_identity: set.leader, now: ::Time.now.to_f))
      end

      # Materialized before paging so `total` counts live processes rather
      # than `SCARD processes`, which still holds identities whose heartbeat
      # lapsed. ProcessSet#each already costs one pipeline for the whole set,
      # so walking it in full buys the accurate count for nothing.
      def index(request)
        window = Page.window!(request)
        set = ::Wurk::ProcessSet.new(false)
        live = set.to_a
        leader = set.leader
        now = ::Time.now.to_f
        rows = Page.slice(live, window) do |process|
          Serializers.process_row(process, leader: leader?(process, leader), now: now)
        end
        Response.json(200, total: live.size, page: window.page, count: window.count, processes: rows)
      end

      # The same row the listing emits, plus what this process is running, so
      # a client that read a row out of `/processes` and then fetched it does
      # not have to reshape anything.
      def show(request)
        identity = Validation.identity!(request.path_params[:identity].to_s)
        process = ::Wurk::ProcessSet[identity]
        return process_not_found(request, identity) unless process

        now = ::Time.now.to_f
        Response.json(
          200,
          process: Serializers.process_row(process, leader: process.leader?, now: now),
          work: work_for(identity, now)
        )
      end

      def busy(request)
        window = Page.window!(request)
        now = ::Time.now.to_f
        rows = ::Wurk::WorkSet.new.to_a
        jobs = Page.slice(rows, window) { |row| Serializers.work_row(*row, now: now) }
        Response.json(200, total: rows.size, page: window.page, count: window.count, jobs: jobs)
      end

      # Re-derived, not proxied. {Wurk::Health} is a raw TCPServer inside each
      # worker process, answering about its own launcher and its own
      # heartbeat; this runs in a process that has neither, so it answers the
      # same two questions — is Redis reachable, is anything beating — about
      # the cluster instead. `quiet` is reported but not folded into the
      # verdict: a draining process is still finishing work, and Health does
      # not fail readiness for it either.
      #
      # Not a Kubernetes probe replacement — a probe must not carry a bearer
      # token. `config.health_check(port:)` is still that surface.
      def health(_request)
        redis = ping_redis
        return unhealthy(redis, nil, 'redis unreachable') unless redis[:ok]

        counts = process_health
        return unhealthy(redis, counts, 'no live processes') if counts[:live].zero?

        Response.json(200, health_body('ok', redis, counts))
      end

      def limiters(request)
        query = Page.query!(request)
        window = Page.window(query)
        names = ::Wurk::Web::Enterprise::Limits.list(filter: filter!(query))
        rows = Page.slice(names, window) { |name| limiter_row(name) }
        Response.json(200, total: names.size, page: window.page, count: window.count, limiters: rows)
      end

      # Walked in full before serializing. LoopSet#each yields from inside its
      # own Redis checkout and Loop#last_fired_at takes another, so serializing
      # mid-iteration would hold a pool slot for the length of the listing.
      # The registry is a deploy-sized list, not a job-sized one.
      def cron(request)
        window = Page.window!(request)
        loops = ::Wurk::Cron::LoopSet.new.to_a
        now = ::Time.now.to_i
        rows = Page.slice(loops, window) { |loop_obj| Serializers.cron_loop(loop_obj, now: now) }
        Response.json(200, total: loops.size, page: window.page, count: window.count, cron: rows)
      end

      def quiet(request) = signal(request, :quiet!, QUIET_SIGNAL)
      def stop(request) = signal(request, :stop!, STOP_SIGNAL)

      # Both signals go through {Wurk::Process#quiet!} / `#stop!` — the same
      # `<identity>-signals` LPUSH the Busy page sends — rather than a second
      # writer to that list. Asynchronous by construction: the target picks the
      # entry up on its next beat, so 200 means queued, never applied.
      def signal(request, method, name)
        identity = request.path_params[:identity].to_s
        return broadcast(method, name) if identity == ALL

        Validation.identity!(identity)
        process = ::Wurk::ProcessSet[identity]
        return process_not_found(request, identity) unless process
        return process_not_signalable(request, identity) if process.embedded?

        process.public_send(method)
        signal_result(name, [identity], [])
      end

      # One answer shape for both ways of addressing, so a client that
      # broadcasts and a client that names one process parse the same body.
      # An embedded process is skipped here rather than refused: a broadcast
      # asks about the fleet, and one member that cannot be signalled is no
      # reason to refuse the rest.
      def broadcast(method, name)
        sent = []
        skipped = []
        ::Wurk::ProcessSet.new(false).each do |process|
          next skipped << process.identity if process.embedded?

          process.public_send(method)
          sent << process.identity
        end
        signal_result(name, sent, skipped)
      end

      def signal_result(name, sent, skipped)
        Response.json(200, signal: name, signalled: sent, skipped: skipped)
      end

      def leader?(process, leader_identity)
        !leader_identity.to_s.empty? && process.identity == leader_identity
      end

      # Filtered out of the canonical WorkSet rather than read straight off
      # `<identity>:work`: a second reader of that hash is a second place for
      # the run_at ordering and the JobRecord unwrapping to drift.
      def work_for(identity, now)
        ::Wurk::WorkSet.new.filter_map do |process_id, thread_id, work|
          next unless process_id == identity

          Serializers.work_row(process_id, thread_id, work, now: now)
        end
      end

      def process_health
        now = ::Time.now.to_f
        live = ::Wurk::ProcessSet.new(false).to_a
        stale = live.count { |entry| Serializers.stale?(Serializers.beat_age_seconds(entry['beat'], now)) }
        { total: live.size, live: live.size - stale, stale: stale, quiet: live.count(&:stopping?) }
      end

      # A 503 whose body is the report itself, not a problem document: an
      # unhealthy cluster is the answer this route was asked for, and Health's
      # own `{"status":"down","reason":…}` is the shape operators already read.
      def unhealthy(redis, processes, reason)
        Response.json(503, health_body('down', redis, processes).merge(reason: reason))
      end

      def health_body(status, redis, processes)
        { status: status, redis: redis, processes: processes,
          stale_after_seconds: Serializers::STALE_AFTER_SECONDS }
      end

      # Its own PING rather than a byproduct of another read: "is Redis
      # reachable" has to stay answerable when every other read would raise.
      def ping_redis
        started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
        pong = ::Wurk.redis(idempotent: true) { |conn| conn.call('PING') } == 'PONG'
        elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond) - started
        { ok: pong, rtt_ms: (elapsed / 1000.0).round(3) }
      rescue ::StandardError
        { ok: false, rtt_ms: nil }
      end

      # Two reads per row — the metadata HASH, then the limiter's own counters
      # — which is what the page cap bounds. Limits owns the metadata and only
      # the limiter type knows where its state lives, so there is no single key
      # to pipeline both out of. Rebuilt from the metadata already in hand
      # rather than through Limits.rebuild, which would re-read it.
      def limiter_row(name)
        meta = ::Wurk::Web::Enterprise::Limits.metadata(name)
        Serializers.limiter_row(name, meta, limiter_status(name, meta))
      end

      # Best-effort in the two ways a persisted limiter can refuse to come
      # back: `build` answers nil for a type this version no longer knows, and
      # the constructor raises ArgumentError on options it cannot accept (a
      # `bucket` whose `interval` is gone, a name written by a later release).
      # A row with a null status is a better answer than a 500 for the whole
      # page. Deliberately not `rescue StandardError` — a broader net would
      # also swallow a bug in the rebuild and report it as a missing status.
      def limiter_status(name, meta)
        ::Wurk::Limiter.build(name, meta['type'], Serializers.parse_options(meta['options']))&.status
      rescue ::ArgumentError, ::TypeError
        nil
      end

      # A repeated `?filter=a&filter=b` parses to an Array, and an unbounded
      # one is a substring scan over every limiter name run on the caller's
      # behalf — both answered rather than coerced.
      def filter!(query)
        raw = query['filter']
        return nil if raw.nil? || raw == ''
        return raw if raw.is_a?(::String) && raw.length <= MAX_FILTER_LENGTH

        raise Validation::Invalid, "The 'filter' parameter is a string of up to #{MAX_FILTER_LENGTH} characters."
      end

      def process_not_found(request, identity)
        Problem.render(
          Problem::PROCESS_NOT_FOUND,
          status: 404,
          detail: "No live process has identity #{identity}; it has exited, or its heartbeat expired.",
          instance: request.path,
          identity: identity
        )
      end

      # 409, not 400: the request is well-formed and the caller is entitled to
      # make it — the target is simply in a state that cannot accept it.
      def process_not_signalable(request, identity)
        Problem.render(
          Problem::PROCESS_NOT_SIGNALABLE,
          status: 409,
          detail: "Process #{identity} is embedded in its host application; signalling it would signal the host.",
          instance: request.path,
          identity: identity
        )
      end
    end
  end
end
