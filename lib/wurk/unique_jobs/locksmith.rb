# frozen_string_literal: true

module Wurk
  module UniqueJobs
    # The keys of one digest, named as the gem names them.
    class Key
      attr_reader :digest, :queued, :primed, :locked, :info, :changelog, :digests, :expiring_digests

      def initialize(digest)
        @digest = digest
        @queued = "#{digest}:QUEUED"
        @primed = "#{digest}:PRIMED"
        @locked = "#{digest}:LOCKED"
        @info = "#{digest}:INFO"
        @changelog = CHANGELOGS
        @digests = DIGESTS
        @expiring_digests = EXPIRING_DIGESTS
      end

      def to_s = digest
      def inspect = digest
      def ==(other) = other.is_a?(Key) && digest == other.digest
      def to_a = [digest, queued, primed, locked, info, changelog, digests, expiring_digests]
    end

    # The lock options of one payload, read the way the gem reads them.
    class LockConfig
      attr_reader :type, :job, :limit, :timeout, :ttl, :pttl, :lock_info, :on_conflict, :errors

      def self.from_worker(options) = new(UniqueJobs.deep_stringify(options))

      def initialize(job_hash = {})
        @type = job_hash[LOCK]&.to_sym
        @job = UniqueJobs.safe_constantize(job_hash[CLASS])
        read_timing(job_hash)
        @lock_info = job_hash.fetch(LOCK_INFO) { UniqueJobs.config.lock_info }
        @on_conflict = job_hash.fetch(ON_CONFLICT) { UniqueJobs.config.on_conflict }
        @errors = job_hash.fetch('errors') { {} }
        @on_client_conflict = job_hash[ON_CLIENT_CONFLICT]
        @on_server_conflict = job_hash[ON_SERVER_CONFLICT]
      end

      def lock_info? = lock_info
      # A nil timeout waits, like the gem: `lock_timeout: nil` means "wait for it".
      def wait_for_lock? = timeout.nil? || timeout.positive?
      def valid? = errors.empty?

      def errors_as_string
        return if valid?

        "\t#{errors.map { |key, val| "#{key}: :#{val}" }.join("\n\t")}"
      end

      def on_client_conflict = @on_client_conflict ||= conflict_for('client')
      def on_server_conflict = @on_server_conflict ||= conflict_for('server')

      private

      def read_timing(job_hash)
        @limit = job_hash.fetch(LOCK_LIMIT, 1)&.to_i
        @timeout = job_hash.fetch(LOCK_TIMEOUT, 0)&.to_i
        @ttl = job_hash.fetch(LOCK_TTL) { job_hash.fetch(LOCK_EXPIRATION, nil) }.to_i
        @pttl = ttl * 1_000
      end

      def conflict_for(origin)
        return on_conflict unless on_conflict.is_a?(::Hash)

        on_conflict[origin] || on_conflict[origin.to_sym]
      end
    end

    # Runs a lock script. A script the server failed comes back as
    # Script::LuaError, as the gem raises it, so an app's existing rescue still
    # applies; any other Redis error passes through unchanged.
    module Script
      Source = ::Struct.new(:path, :source)

      # The gem's script names, which its changelog entries carry.
      NAMES = {
        unique_jobs_queue_and_lock: 'queue_and_lock.lua', unique_jobs_queue: 'queue.lua',
        unique_jobs_lock: 'lock.lua', unique_jobs_unlock: 'unlock.lua', unique_jobs_delete: 'delete.lua',
        unique_jobs_delete_by_digest: 'delete_by_digest.lua',
        unique_jobs_delete_job_by_digest: 'delete_job_by_digest.lua'
      }.freeze

      def self.call(name, conn, keys:, argv: [])
        Wurk::Lua::Loader.eval_cached(conn, name, keys: keys, argv: argv)
      rescue RedisClient::CommandError => e
        raise unless LuaError.intercepts?(e)

        raise LuaError.new(e, Source.new(File.join(Wurk::Lua::LUA_DIR, "#{name}.lua"), Wurk::Lua::SCRIPTS[name]))
      end
    end

    # Takes, waits for and drops the lock of one job. Same keys and transitions
    # as the gem's Locksmith; see the scripts named `unique_jobs_*.lua`.
    class Locksmith
      include Reflectable

      CLOCK_DRIFT_FACTOR = 0.01
      # A blocking wait never parks a web request longer than this, as the gem caps it.
      MAX_BLOCKING_WAIT = 5

      attr_reader :key, :job_id, :config, :item

      def initialize(item, _redis_pool = nil)
        @item = item
        @key = Key.new(item[LOCK_DIGEST] || item[UNIQUE_DIGEST])
        @job_id = item[JID]
        @config = LockConfig.new(item)
        @sync_locked = false
      end

      # Without a wait: one script, no queue. With one (even 0): queue, then
      # block on the QUEUED list up to `wait` seconds, then lock.
      def lock(wait: nil)
        UniqueJobs.redis do |conn|
          if wait.nil?
            return job_id if acquired_sync?(conn)
          elsif locked?(conn) || acquired_blocking?(conn, wait)
            return job_id
          end
        end
        nil
      end

      # Runs the block when the lock is (or becomes) this job's, else returns nil.
      def execute
        raise InvalidArgument, '#execute needs a block' unless block_given?

        run&.mark(key.digest)
        acquired = UniqueJobs.redis { |conn| claimed?(conn) || acquired_blocking?(conn, nil) }
        yield if acquired
      end

      def unlock(conn = nil) = unlock!(conn)

      def unlock!(conn = nil)
        jid = run_script(:unique_jobs_unlock, conn, argv + [@sync_locked ? 1 : 0, run_token])
        reflect(:unlocked, item) if jid == job_id
        jid
      end

      def delete
        return if config.pttl.positive?

        delete!
      end

      # rubocop:disable-next Naming/PredicateMethod -- the gem's name
      def delete! = run_script(:unique_jobs_delete, nil, argv).to_i.positive?

      def locked?(conn = nil)
        return conn.call('HEXISTS', key.locked, job_id) == 1 if conn

        UniqueJobs.redis { |c| c.call('HEXISTS', key.locked, job_id) == 1 }
      end

      def to_s = "Locksmith##{object_id}(digest=#{key} job_id=#{job_id} locked=#{locked?})"
      def inspect = to_s
      def ==(other) = key == other.key && job_id == other.job_id

      private

      def acquired_sync?(conn)
        jid, elapsed = timed { run_script(:unique_jobs_queue_and_lock, conn, argv) }
        return false unless jid == job_id && valid_for?(elapsed)

        @sync_locked = true
        write_lock_info(conn)
        true
      end

      def acquired_blocking?(conn, wait)
        jid, elapsed = timed { run_script(:unique_jobs_queue, conn, argv) }
        return false unless jid && [job_id, '1'].include?(jid) && valid_for?(elapsed)

        write_lock_info(conn)
        return false unless primed?(conn, wait)

        !run_script(:unique_jobs_lock, conn, argv + [run_token]).nil?
      end

      def primed?(conn, wait)
        timeout = (wait || config.timeout).to_i
        timeout = 1 if timeout.zero?
        primed_jid = pop_queued(conn, timeout)
        return true if [job_id, '1'].include?(primed_jid)

        reflect(:timeout, item) unless config.wait_for_lock?
        false
      end

      def pop_queued(conn, wait)
        raise InvalidArgument, 'wait must be an integer' unless wait.is_a?(::Integer)
        raise InvalidArgument, 'wait must be positive' if wait.negative?

        wait = [wait, MAX_BLOCKING_WAIT].min
        conn.blocking_call(wait, 'BLMOVE', key.queued, key.primed, 'RIGHT', 'LEFT', wait)
      end

      # A lock whose script outran its own TTL is not trusted, as in the gem.
      def valid_for?(elapsed_ms)
        pttl = config.pttl
        pttl.zero? || pttl - elapsed_ms - ((pttl + 2).to_f * CLOCK_DRIFT_FACTOR) >= 0
      end

      # The lock's own arguments, then what every script appends: the time, the
      # changelog cap and the gem's script name; what only one script takes goes last.
      def run_script(script, conn, args)
        injected = [UniqueJobs.now_f, UniqueJobs.config.max_history.to_i, Script::NAMES.fetch(script)]
        full = args.first(5) + injected + args.drop(5)
        return Script.call(script, conn, keys: key.to_a, argv: full) if conn

        UniqueJobs.redis { |c| Script.call(script, c, keys: key.to_a, argv: full) }
      end

      def run = Run.of(item)
      def run_token = run&.token_for(key.digest).to_s

      # Enters a lock this jid already holds, as its newest run.
      def claimed?(conn)
        return locked?(conn) unless run

        Script.call(:unique_jobs_claim, conn, keys: key.to_a, argv: [job_id, run_token]) == 1
      end

      def argv = [job_id, config.pttl, config.type.to_s, config.limit.to_i, item[AT].to_s]

      def write_lock_info(conn)
        return unless config.lock_info?

        conn.call('SET', key.info, Wurk.dump_json(lock_info))
      end

      def lock_info
        {
          WORKER => item[CLASS], QUEUE => item[QUEUE], LIMIT => item[LOCK_LIMIT], TIMEOUT => item[LOCK_TIMEOUT],
          TTL => item[LOCK_TTL], TYPE => config.type, LOCK_ARGS => item[LOCK_ARGS], TIME => UniqueJobs.now_f,
          AT => item[AT]
        }
      end

      def timed
        start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond)
        [yield, ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond) - start]
      end
    end
  end
end
