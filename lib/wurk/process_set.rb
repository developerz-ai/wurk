# frozen_string_literal: true

module Wurk
  # Live process list view backed by the `processes` SET + per-identity hashes.
  # Cluster topology lives here: dashboard process list, total concurrency
  # gauge, RSS roll-up, leader lookup.
  #
  # Wire-compat is sacred — every Redis call matches Sidekiq OSS exactly.
  # Spec: docs/target/sidekiq-free.md §1 (Redis schema), §19.6.
  class ProcessSet
    include Enumerable

    # Order matters — index-aligned with the HMGET row.
    BEAT_FIELDS = %w[busy beat quiet rss rtt_us].freeze
    EACH_FIELDS = (%w[info concurrency] + BEAT_FIELDS).freeze
    LOOKUP_FIELDS = (%w[info] + BEAT_FIELDS).freeze
    private_constant :BEAT_FIELDS, :EACH_FIELDS, :LOOKUP_FIELDS

    # `processes` SET only stores identity strings; the live hash at each
    # identity expires every 60s, so SCARD can lag reality. Constructor
    # opts into a `cleanup` (rate-limited globally to 1/min) so the size
    # reported below reflects the post-prune state — except when caller
    # explicitly skips it (e.g. inside `cleanup` itself, or for snapshot
    # reads on hot paths).
    #
    # Positional Boolean matches Sidekiq's public API — wire-compat sacred.
    def initialize(clean_plz = true) # rubocop:disable Style/OptionalBooleanParameter
      cleanup if clean_plz
    end

    # Fetch a single Process by identity. Pipelined SISMEMBER + HMGET so
    # absence (process never registered) and expiry (heartbeat lapsed,
    # info field gone) both return nil.
    def self.[](identity)
      exists, fields = Wurk.redis do |conn|
        conn.pipelined do |pipe|
          pipe.call('SISMEMBER', Keys::PROCESSES, identity)
          pipe.call('HMGET', identity, *LOOKUP_FIELDS)
        end
      end
      return nil if exists.to_i.zero? || fields.first.nil?

      build_process(LOOKUP_FIELDS.zip(fields).to_h)
    end

    # SREM identities whose `info` HASH field has expired. Rate-limited
    # globally to 1/min via SET NX EX so concurrent dashboards / API calls
    # don't dogpile the prune. Returns the number of identities removed
    # (or 0 when the lock was held by someone else).
    #
    # Spec: docs/target/sidekiq-free.md §31.17.
    def cleanup
      return 0 unless acquired_cleanup_lock?

      Wurk.redis do |conn|
        procs = conn.call('SMEMBERS', Keys::PROCESSES)
        next 0 if procs.empty?

        heartbeats = conn.pipelined do |pipe|
          procs.each { |key| pipe.call('HGET', key, 'info') }
        end
        to_prune = procs.zip(heartbeats).filter_map { |id, info| id if info.nil? }
        next 0 if to_prune.empty?

        conn.call('SREM', Keys::PROCESSES, *to_prune).to_i
      end
    end

    # Pipelined identity → HMGET. Skips identities whose `info` field is
    # gone (heartbeat expired between SMEMBERS and HMGET). Sorted by
    # identity so iteration order is stable for dashboards.
    def each
      return enum_for(:each) unless block_given?

      rows = fetch_each_rows
      rows.each do |row|
        attrs = EACH_FIELDS.zip(row).to_h
        next if attrs['info'].nil?

        yield ProcessSet.send(:build_process, attrs)
      end
    end

    # SCARD over `processes`. Not pruned — may include identities whose
    # heartbeat has lapsed. Use `each` for the accurate count.
    def size
      Wurk.redis { |conn| conn.call('SCARD', Keys::PROCESSES) }
    end

    # Sum of `concurrency` across live processes. Iterates `each` so dead
    # identities are skipped.
    def total_concurrency
      sum { |p| p['concurrency'].to_i }
    end

    # Sum of `rss` (KB) across live processes.
    def total_rss_in_kb
      sum { |p| p['rss'].to_i }
    end
    alias total_rss total_rss_in_kb

    # Cluster leader identity. Ent-only feature; OSS only reads the key.
    # Memoized per-instance: dashboards re-instantiate ProcessSet per render.
    # `||=` with empty-string fallback distinguishes "leader is unset" from
    # "memoization not yet computed".
    def leader
      @leader ||= Wurk.redis { |c| c.call('GET', 'dear-leader') } || ''
    end

    class << self
      private

      # Builds a Wurk::Process from `{field_name => raw_value}`. Handles
      # both the 6-field `[]` shape and the 7-field `each` shape — extra
      # `concurrency` from the heartbeat overrides whatever `info` JSON
      # claimed (heartbeat is fresher).
      def build_process(attrs)
        hash = Wurk.load_json(attrs.fetch('info')).merge(beat_overrides(attrs))
        hash['concurrency'] = attrs['concurrency'].to_i if attrs.key?('concurrency')
        Process.new(hash)
      end

      def beat_overrides(attrs)
        {
          'busy' => attrs['busy'].to_i,
          'beat' => attrs['beat'].to_f,
          'quiet' => attrs['quiet'],
          'rss' => attrs['rss'].to_i,
          'rtt_us' => attrs['rtt_us'].to_i
        }
      end
    end

    private

    def fetch_each_rows
      Wurk.redis do |conn|
        procs = conn.call('SMEMBERS', Keys::PROCESSES).sort
        next [] if procs.empty?

        conn.pipelined do |pipe|
          procs.each { |key| pipe.call('HMGET', key, *EACH_FIELDS) }
        end
      end
    end

    def acquired_cleanup_lock?
      Wurk.redis { |conn| conn.call('SET', 'process_cleanup', '1', 'NX', 'EX', '60') } == 'OK'
    end
  end

  # One row in the process list. `attribs` is the merged `info` JSON +
  # per-beat fields (busy, beat, quiet, rss, rtt_us). All fields are
  # read-only — mutations happen via signals (`<id>-signals` LIST), not
  # by editing this hash.
  #
  # Spec: docs/target/sidekiq-free.md §19.6.
  class Process
    def initialize(hash)
      @attribs = hash
    end

    def tag      = self['tag']
    def labels   = self['labels'].to_a
    def [](key)  = @attribs[key]
    def identity = self['identity']
    alias id identity

    # Back-compat for dashboards predating capsules (pre-v8.0.8). New
    # heartbeats write `capsules`; fall through to the legacy `queues`
    # field if the process hasn't been upgraded yet.
    def queues
      if self['capsules']
        capsules.values.flat_map { |c| c['weights'].keys }.uniq
      else
        self['queues']
      end
    end

    # Back-compat sibling of `queues`. Two capsules processing the same
    # queue name will collapse to a single weight — there's no useful way
    # to merge them and the dashboard never displayed both.
    def weights
      return self['weights'] unless self['capsules']

      capsules.values.each_with_object({}) do |cap, acc|
        cap['weights'].each { |q, w| acc[q] = w }
      end
    end

    def capsules  = self['capsules']
    def version   = self['version']
    def embedded? = self['embedded']

    # SIGTSTP — drop fetch, drain in-flight. Asynchronous; takes one
    # heartbeat (≤10s) for the target process to notice.
    def quiet!
      raise 'Cannot quiet an embedded process' if embedded?

      signal('TSTP')
    end

    # SIGTERM — graceful shutdown within `shutdown_timeout`. Asynchronous.
    def stop!
      raise 'Cannot stop an embedded process' if embedded?

      signal('TERM')
    end

    # SIGTTIN — dump every thread's backtrace. For diagnosing frozen
    # processes that are still beating.
    def dump_threads
      signal('TTIN')
    end

    # Truthy when this process has accepted a TSTP and won't fetch new
    # jobs. The heartbeat writes `quiet = "true"` after handling the
    # signal — read-only here.
    def stopping?
      self['quiet'] == 'true'
    end

    # Compares identity against the `dear-leader` STRING. Ent-only;
    # always false in OSS/free.
    def leader?
      Wurk.redis { |c| c.call('GET', 'dear-leader') == identity }
    end

    private

    # LPUSH to `<identity>-signals` + EXPIRE 60s. Pipelined so a crashed
    # caller can't leave a stray key behind without a TTL.
    def signal(sig)
      key = "#{identity}-signals"
      Wurk.redis do |c|
        c.pipelined do |pipe|
          pipe.call('LPUSH', key, sig)
          pipe.call('EXPIRE', key, 60)
        end
      end
    end
  end
end
