# frozen_string_literal: true

require_relative '../engine_test_helper'

# Proves Wurk::SameOriginGuard (#101 web/API hardening) actually rejects
# forged cross-site mutations and lets real same-origin traffic through, for
# every mutating route the engine exposes — not just the handful individual
# suites happen to cover with the header pre-set in `setup`.
#
# Route-table-derived, complete by construction: `all_mutating_routes` walks
# ::Wurk::Engine.routes at runtime and keeps every route on a
# SameOriginGuard-protected controller (ApiController, ExtensionsController)
# whose verb is outside the guard's SAFE_METHODS, so a mutating route added
# to config/routes.rb is probed automatically. It used to be a handwritten
# path list, and it silently missed POST /api/flows/:fid/abandon when that
# route shipped — the drift this derivation exists to prevent. A route the
# test cannot materialize into a concrete path raises instead of skipping,
# so coverage can never silently shrink again.
#
# The 403 direction needs no seeded data — the guard runs in a `before_action`
# and rejects before the action ever touches Redis, so arbitrary path params
# are safe to probe. The 2xx direction drops the three `.../all/:cmd`
# bulk-drain routes (retries/scheduled/dead): they UNLINK the *global* zset
# wholesale, and other parallelize_me! suites in this worker's Redis DB push
# fixtures onto those same un-namespaced keys — draining them here would
# flake sibling tests for a property those suites already cover directly
# (ApiMutationsTest).
class CsrfSameOriginTest < Wurk::Test::EngineCase
  # Deliberately NOT parallelize_me!, for the same reason ApiMutationsTest isn't:
  # the 2xx pass depends on fixtures living in the global retry/scheduled/dead
  # zsets, and ApiMutationsTest drives `/wurk/api/<set>/all/<cmd>` — which drains
  # those zsets wholesale. Minitest runs non-parallel tests serially in the
  # runner thread, so opting out is what makes the two suites unable to
  # interleave; a `parallelize_me!` here put this class in the executor pool
  # alongside them and the drain landed between this suite's `setup` and its
  # POST. Three tests, all sub-second — there is nothing to win by parallelising
  # them anyway.

  # Route verb segments that mutate state — the complement of the guard's
  # safe-method allowlist over the verbs Rails' DSL can generate.
  MUTATING_VERBS = %w[GET HEAD POST PUT PATCH DELETE OPTIONS TRACE]
                   .difference(::Wurk::SameOriginGuard::SAFE_METHODS).freeze

  # The guard-protected controllers, keyed by the engine-relative controller
  # name route.defaults carries. DashboardController and ProfilesController
  # serve GET-only routes; the Wurk::API mount answers nil (no :controller
  # default) and is token-authenticated, not cookie-ambient — outside the CSRF
  # surface by design.
  GUARDED_CONTROLLERS = { 'wurk/api' => true, 'wurk/extensions' => true }.freeze

  # `/wurk` — where test/dummy mounts the engine. Route path specs are
  # engine-relative; the probes hit the full app.
  ENGINE_MOUNT = '/wurk'

  def setup
    super
    @ns = "wurkcsrf:#{::Process.pid}:#{object_id}"
    @queue = "#{@ns}-clear-q"
    @del_queue = "#{@ns}-del-q"
    @class_name = "CsrfJob@#{@ns}"
    @lid = ::Digest::SHA1.hexdigest(@ns)[0, 16]
    @limiter = "lmt-#{@ns}"
    @identity = "host-#{@ns}:1:aa"

    @del_jid = seed_queue_job(@del_queue)
    @retry_key = seed_zset_entry('retry')
    @sched_key = seed_zset_entry('schedule')
    @dead_key = seed_zset_entry('dead')
    seed_cron_loop
    seed_process(@identity)
    @flow = ::Wurk::Flow.new { |f| f.job("CsrfFlowHead#{@ns}", queue: @queue) }.run
  end

  def teardown
    ::Wurk.redis do |c|
      # queue:#{@queue} holds the flow's root job — Flow.abandon deliberately
      # leaves queued jobs on their queue lists, so teardown drops the list
      # itself or the payload is orphaned in this worker's Redis DB until expiry.
      c.call('DEL', "queue:#{@del_queue}", "queue:#{@queue}")
      c.call('SREM', 'queues', @del_queue, @queue)
      c.call('SREM', ::Wurk::Keys::PAUSED_SET, @queue)
      cleanup_zset(c, 'retry')
      cleanup_zset(c, 'schedule')
      cleanup_zset(c, 'dead')
      c.call('SREM', ::Wurk::Cron::PERIODIC_KEY, @lid)
      c.call('DEL', "#{::Wurk::Cron::LOOP_PREFIX}#{@lid}", "#{::Wurk::Cron::HISTORY_PREFIX}#{@lid}")
      c.call('SREM', ::Wurk::Keys::PROCESSES, @identity)
      c.call('DEL', @identity, "#{@identity}-signals")
      release_flow(c, @flow)
    end
  ensure
    super
  end

  # Every mutating route on a SameOriginGuard-protected controller, derived
  # from the engine's route table — no handwritten path list. Each entry is
  # the concrete /wurk-prefixed path plus the params the action needs.
  def all_mutating_routes
    ::Wurk::Engine.routes.routes.filter_map do |route|
      next unless GUARDED_CONTROLLERS[route.defaults[:controller]]
      next unless route.verb.split('|').intersect?(MUTATING_VERBS)

      materialize(route)
    end
  end

  # `.../all/:cmd` bulk-drain routes wipe the whole global zset — excluded
  # here (see class comment); everything else must reach the controller and
  # succeed for a genuine same-origin request.
  def safe_2xx_routes
    all_mutating_routes.reject { |r| r[:path].include?('/all/') }
  end

  def test_every_mutating_route_403s_without_same_origin_header
    all_mutating_routes.each do |route|
      post route[:path], route[:params] || {}

      assert_equal 403, last_response.status,
                   "expected 403 for POST #{route[:path]} without Sec-Fetch-Site, got #{last_response.status}"
    end
  end

  def test_every_safe_route_succeeds_with_same_origin_header
    header 'Sec-Fetch-Site', 'same-origin'

    safe_2xx_routes.each do |route|
      post route[:path], route[:params] || {}

      assert_includes 200..299, last_response.status,
                      "expected 2xx for POST #{route[:path]} with Sec-Fetch-Site: same-origin, " \
                      "got #{last_response.status}: #{last_response.body[0, 300]}"
    end
  end

  # Reads (GET, incl. SSE) are safe methods — SameOriginGuard never blocks
  # them, header or not. Sanity check so the guard's SAFE_METHODS allowlist
  # doesn't regress into blocking dashboard reads.
  def test_get_requests_are_never_blocked
    get '/wurk/api/stats'

    assert_equal 200, last_response.status
  end

  private

  # Turns one derived route into a concrete probe. A route whose spec no
  # PROBED_SPECS entry claims raises — never skips — so a new mutating route
  # fails loudly here instead of silently shrinking the coverage.
  def materialize(route)
    spec = route.path.spec.to_s.delete_suffix('(.:format)')
    unless PROBED_SPECS.include?(spec)
      raise "CsrfSameOriginTest has no probe for #{route.verb} #{spec} — add a PROBE_FIXTURES entry"
    end

    path = "#{ENGINE_MOUNT}#{fill_segments(spec)}"
    params = PROBE_PARAMS[spec]
    params ? { path: path, params: params.transform_values { |v| resolve_fixture(v) } } : { path: path }
  end

  # Every mutating route the engine exposes today, keyed by its exact route
  # spec, with what each dynamic segment materializes to: a Symbol naming a
  # seeded fixture (see `fixture_values`) or a literal. These keys pin which
  # fixture a segment takes; they enumerate no coverage — the route table
  # does, and a route without an entry here raises in `materialize`. `:cmd`
  # materializes to 'delete', the one action every set's `all/:cmd` whitelist
  # shares; the 2xx pass drops these bulk drains regardless (class comment).
  # rubocop:disable Lint/UselessConstantScoping
  PROBE_FIXTURES = {
    '/api/queues/:name/clear' => { name: :queue },
    '/api/queues/:name/delete' => { name: :del_queue },
    '/api/queues/:name/pause' => { name: :queue },
    '/api/queues/:name/unpause' => { name: :queue },
    '/api/retries/all/:cmd' => { cmd: 'delete' },
    '/api/retries/:key' => { key: :retry_key },
    '/api/scheduled/all/:cmd' => { cmd: 'delete' },
    '/api/scheduled/:key' => { key: :sched_key },
    '/api/dead/all/:cmd' => { cmd: 'delete' },
    '/api/dead/:key' => { key: :dead_key },
    '/api/flows/:fid/abandon' => { fid: :flow_fid },
    '/api/limiters/:name/reset' => { name: :limiter },
    '/api/cron/:lid/pause' => { lid: :lid },
    '/api/cron/:lid/unpause' => { lid: :lid },
    '/api/cron/:lid/enqueue' => { lid: :lid },
    # path.spec spells the glob as Journey stores it: /*subpath, one segment.
    '/ext/:name(/*subpath)' => { name: :unregistered_ext }
  }.freeze

  # All specs the probes cover — the fixture-backed ones plus the
  # segment-free routes that need no materialization.
  PROBED_SPECS = (PROBE_FIXTURES.keys + %w[
    /api/retries /api/scheduled /api/dead /api/busy/quiet /api/busy/stop
  ]).freeze

  # Body params each action needs: a Symbol resolves to a seeded fixture,
  # anything else is a literal.
  PROBE_PARAMS = {
    '/api/queues/:name/delete' => { jid: :del_jid },
    '/api/retries' => { cmd: 'delete', keys: [] },
    '/api/retries/:key' => { cmd: 'delete' },
    '/api/scheduled' => { cmd: 'delete', keys: [] },
    '/api/scheduled/:key' => { cmd: 'delete' },
    '/api/dead' => { cmd: 'delete', keys: [] },
    '/api/dead/:key' => { cmd: 'retry' },
    '/api/busy/quiet' => { identity: :identity },
    '/api/busy/stop' => { identity: :identity }
  }.freeze
  # rubocop:enable Lint/UselessConstantScoping

  # The seeded values fixture symbols resolve to for this test instance.
  def fixture_values
    @fixture_values ||= {
      queue: @queue, del_queue: @del_queue, del_jid: @del_jid,
      retry_key: @retry_key, sched_key: @sched_key, dead_key: @dead_key,
      flow_fid: @flow.fid, limiter: @limiter, lid: @lid,
      identity: @identity, unregistered_ext: "csrf-unregistered-#{@ns}"
    }
  end

  def resolve_fixture(value)
    value.is_a?(Symbol) ? fixture_values.fetch(value) : value
  end

  def fill_segments(spec)
    fixtures = PROBE_FIXTURES.fetch(spec) { {} }
    # Journey marks optional glob segments "(/*name)" — materialize them
    # empty (the route's default), then fill the dynamic segments.
    spec.gsub(%r{\(/\*[a-z_]+\)}, '').gsub(/:([a-z_]+)/) do
      segment = ::Regexp.last_match(1)
      resolve_fixture(fixtures.fetch(segment.to_sym) do
        raise "CsrfSameOriginTest cannot materialize :#{segment} in #{spec} — add a fixture to PROBE_FIXTURES"
      end)
    end
  end

  def seed_queue_job(queue)
    jid = ::SecureRandom.hex(12)
    payload = {
      'class' => @class_name, 'args' => [1], 'queue' => queue, 'jid' => jid,
      'created_at' => ::Time.now.to_f, 'enqueued_at' => ::Time.now.to_f, 'retry_count' => 0
    }
    ::Wurk.redis do |c|
      c.call('SADD', 'queues', queue)
      c.call('LPUSH', "queue:#{queue}", ::Wurk.dump_json(payload))
    end
    jid
  end

  # Seeds one entry in the given global zset, returning its URL-encoded
  # "<score>|<jid>" route key (matches the SPA's encodeURIComponent).
  #
  # Scored an hour out, never `Time.now`. `retry` and `schedule` are global,
  # un-namespaced keys (wire-compat — they cannot be namespaced per test), and a
  # due entry in either is fair game for any poller running in a sibling suite
  # on this worker's Redis DB: it gets promoted onto its queue, leaves the zset,
  # and the route below 404s on a fixture that was there in `setup`. A future
  # score is invisible to every poller and changes nothing this test asserts —
  # the route key is just "<score>|<jid>".
  def seed_zset_entry(name)
    score = ::Time.now.to_f + 3600
    jid = ::SecureRandom.hex(12)
    payload = {
      'class' => @class_name, 'args' => [1], 'queue' => @queue, 'jid' => jid,
      'created_at' => score, 'enqueued_at' => score, 'retry_count' => 1,
      'error_class' => 'RuntimeError', 'error_message' => 'boom'
    }
    ::Wurk.redis { |c| c.call('ZADD', name, score.to_s, ::Wurk.dump_json(payload)) }
    ::CGI.escape("#{score}|#{jid}")
  end

  def seed_cron_loop
    ::Wurk.redis do |c|
      c.call('SADD', ::Wurk::Cron::PERIODIC_KEY, @lid)
      c.call(
        'HSET', "#{::Wurk::Cron::LOOP_PREFIX}#{@lid}",
        'schedule', '* * * * *', 'klass', @class_name,
        'options', ::JSON.dump('queue' => @queue, 'args' => [1]), 'tz', '', 'paused', '0'
      )
    end
  end

  def seed_process(identity)
    info = {
      'hostname' => 'testhost', 'pid' => 1234, 'tag' => @ns, 'concurrency' => 5,
      'queues' => ['default'], 'identity' => identity, 'version' => ::Wurk::VERSION, 'embedded' => false
    }
    ::Wurk.redis do |c|
      c.call('SADD', ::Wurk::Keys::PROCESSES, identity)
      c.call('HSET', identity, 'info', ::Wurk.dump_json(info),
             'busy', '0', 'beat', ::Time.now.to_f.to_s, 'quiet', 'false', 'rss', '1000',
             'rtt_us', '10', 'concurrency', '5')
    end
  end

  # Same sweep FlowEndpointsTest runs for the flows it never abandoned, plus
  # the record abandonment keeps. Abandonment already drops node keys and
  # batches; a second abandon after the 2xx probe is a documented no-op.
  def release_flow(conn, flow)
    ::Wurk::Flow.abandon(flow.fid)
    conn.call('DEL', ::Wurk::Keys.flow(flow.fid))
    conn.call('ZREM', ::Wurk::Keys::FLOWS_SET, flow.fid)
    flow.jids.each_index { |i| conn.call('DEL', ::Wurk::Keys.flow_node(flow.fid, i)) }
  end

  def cleanup_zset(conn, key)
    conn.call('ZRANGEBYSCORE', key, '-inf', '+inf').each do |raw|
      parsed = begin
        ::Wurk.load_json(raw)
      rescue ::JSON::ParserError
        nil
      end
      next unless parsed.is_a?(Hash) && parsed['class'] == @class_name

      conn.call('ZREM', key, raw)
    end
  end
end
