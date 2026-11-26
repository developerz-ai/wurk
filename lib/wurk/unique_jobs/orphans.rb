# frozen_string_literal: true

require_relative '../unique_jobs_compat/private_list_digests'

module Wurk
  module UniqueJobs
    module Orphans
      # Deletes locks no job holds any more: a digest older than `reaper_timeout`
      # plus a beat whose jid is in no queue, private list, schedule, retry set or
      # running job. `until_expired` digests past their expiry go too.
      #
      # Bounded, unlike the gem's RubyReaper, which scans every queue once per
      # digest: the jobs are read once into a set of the digests they carry, and
      # read again after the candidates are picked, so a job that moved between
      # two reads (a retry going back to the retry set) is still seen. At most
      # `reaper_count` digests per run, and the run stops at `reaper_timeout`.
      class Reaper
        BEAT_PAUSE = 10
        # Above this many queued jobs the run is skipped, as the gem skips it.
        MAX_QUEUE_LENGTH = 1_000
        # Above this many scheduled plus retrying jobs the run is skipped too: the
        # orphan scan reads both sets whole, twice. The gem has no such bound.
        MAX_SORTED_SET_SIZE = 100_000
        PAGE = 1_000
        FIELDS = [LOCK_DIGEST, UNIQUE_DIGEST].freeze

        def self.call(conn = nil) = new(conn).call

        def initialize(_conn = nil)
          @config = UniqueJobs.config
          @start = ::Time.now.to_f
          @deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + @config.reaper_timeout.to_i
        end

        # The digests deleted, expired first. Then hand-off lists without a TTL
        # get one, on a budget of their own, whatever the queues hold.
        def call
          deleted = reap_digests
          PrimedSweep.new.call
          deleted
        end

        def reap_digests
          return 0 if queues_very_full? || sorted_sets_very_full?

          BatchDelete.call(expired_digests) + BatchDelete.call(orphans)
        end

        def max_score = @start - @config.reaper_timeout.to_i - BEAT_PAUSE

        def expired_digests
          UniqueJobs.redis do |conn|
            conn.call('ZRANGE', EXPIRING_DIGESTS, 0, max_score, 'BYSCORE', 'LIMIT', 0, @config.reaper_count.to_i)
          end
        end

        def orphans
          candidates = candidate_digests
          return [] if candidates.empty?

          live = LiveDigests.new.call
          return [] if live.busy_since?(max_score)

          candidates.reject! { |digest| live.holds?(digest) }
          return [] if candidates.empty?

          again = LiveDigests.new.call
          return [] if again.busy_since?(max_score)

          candidates.reject { |digest| again.holds?(digest) }
        end

        private

        def candidate_digests
          picked = []
          offset = 0
          until picked.size >= @config.reaper_count.to_i || timed_out?
            page = UniqueJobs.redis do |conn|
              conn.call('ZRANGE', DIGESTS, 0, max_score, 'BYSCORE', 'LIMIT', offset, PAGE)
            end
            break if page.empty?

            picked.concat(page.first(@config.reaper_count.to_i - picked.size))
            offset += PAGE
          end
          picked
        end

        def timed_out? = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= @deadline

        def sorted_sets_very_full?
          sizes = UniqueJobs.redis do |conn|
            conn.pipelined { |pipe| [Keys::SCHEDULE, Keys::RETRY].each { |set| pipe.call('ZCARD', set) } }
          end
          sizes.sum > MAX_SORTED_SET_SIZE
        end

        def queues_very_full?
          total = 0
          queues = UniqueJobs.redis { |conn| conn.call('SMEMBERS', Keys::QUEUES_SET) }
          queues.each_slice(100) do |slice|
            sizes = UniqueJobs.redis { |conn| conn.pipelined { |p| slice.each { |q| p.call('LLEN', Keys.queue(q)) } } }
            total += sizes.sum
            return true if total > MAX_QUEUE_LENGTH
          end
          false
        end
      end

      # `<digest>:PRIMED` lists a Wurk before 1.23 (or the gem) left without a
      # TTL: an entry BLMOVE put there that no lock script took out. The digest
      # reaper never meets them, since a lock that was never taken is in no
      # digest set. A PRIMED entry is a hand-off the lock script takes within
      # the call that moved it, never the lock itself (that is LOCKED), so each
      # such list gets the hand-off TTL: a hand-off in flight still completes,
      # and the leftover expires. Bounded by the reaper's deadline.
      class PrimedSweep
        # Seconds per run. Its own, so the digest reaper using the whole
        # reaper_timeout never starves it; a run that stops early resumes at
        # the next run where this one stopped.
        BUDGET = 2
        GLOB = /[*?\[\]\\]/

        @cursor = '0'
        class << self
          attr_accessor :cursor
        end

        # Glob characters in the prefix are matched literally: a `billing*`
        # prefix must not reach another app's lists.
        def initialize
          prefix = (UniqueJobs.config.lock_prefix || 'uniquejobs').to_s.gsub(GLOB) { |c| "\\#{c}" }
          @match = "#{prefix}:*:PRIMED"
          @deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + BUDGET
        end

        # The lists given a TTL.
        def call
          cursor = self.class.cursor
          fixed = 0
          loop do
            cursor, keys = UniqueJobs.redis { |conn| conn.call('SCAN', cursor, 'MATCH', @match, 'COUNT', Reaper::PAGE) }
            fixed += expire_unbounded(keys) unless keys.empty?
            break if cursor == '0' || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= @deadline
          end
          self.class.cursor = cursor
          fixed
        end

        private

        # PTTL picks the candidates in one round trip; the script re-checks each
        # (still a list, still no TTL) as it sets the TTL.
        def expire_unbounded(keys)
          ttls = UniqueJobs.redis { |conn| conn.pipelined { |pipe| keys.each { |key| pipe.call('PTTL', key) } } }
          unbounded = keys.zip(ttls).filter_map { |key, ttl| key if ttl == -1 }
          UniqueJobs.redis do |conn|
            unbounded.count do |key|
              Wurk::Lua::Loader.eval_cached(conn, :unique_jobs_primed_ttl,
                                            keys: [key], argv: [Locksmith::PRIMED_TTL_MS]) == 1
            end
          end
        end
      end

      # The gem's names for its reapers; `reaper: :lua` runs the Ruby one there too.
      RubyReaper = Reaper
      LuaReaper = Reaper

      # One read of every place a job can be, in the order a job moves through
      # them (schedule and retry, queues, private lists, running), so a job
      # moving forward during the read is seen at least once.
      class LiveDigests
        Result = ::Struct.new(:queued, :running, :newest_running) do
          def holds?(digest) = queued.include?(digest) || running.include?(digest.delete_suffix(RUN_SUFFIX))

          # The gem keeps every lock while any job created after the cutoff runs.
          def busy_since?(cutoff) = newest_running.to_f > cutoff
        end

        def initialize
          @result = Result.new(::Set.new, ::Set.new, 0.0)
        end

        def call
          [Keys::SCHEDULE, Keys::RETRY].each { |set| read_sorted_set(set) }
          queues.each { |queue| read_list(Keys.queue(queue)) }
          private_lists = UniqueJobsCompat::PrivateListDigests.new.call
          @result.queued.merge(private_lists.digests)
          read_running
          @result
        end

        private

        def queues = UniqueJobs.redis { |conn| conn.call('SMEMBERS', Keys::QUEUES_SET) }

        def read_sorted_set(key)
          cursor = '0'
          loop do
            cursor, batch = UniqueJobs.redis { |conn| conn.call('ZSCAN', key, cursor, 'COUNT', Reaper::PAGE) }
            batch.each_slice(2) { |payload, _score| collect(payload, @result.queued) }
            break if cursor == '0'
          end
        end

        # Whole: the run is skipped above MAX_QUEUE_LENGTH queued jobs.
        def read_list(key)
          payloads = UniqueJobs.redis { |conn| conn.call('LRANGE', key, 0, -1) }
          payloads.each { |payload| collect(payload, @result.queued) }
        end

        def read_running
          Wurk::WorkSet.new.each do |_process, _thread, work|
            job = work.payload
            job = parse(job) if job.is_a?(::String)
            next unless job.is_a?(::Hash)

            digests(job).each { |digest| @result.running << digest.delete_suffix(RUN_SUFFIX) }
            @result.newest_running = [@result.newest_running, created_at(job)].max
          end
        end

        def digests(job) = Reaper::FIELDS.filter_map { |field| job[field] if job[field].is_a?(::String) }

        # Wurk and Sidekiq 8 write milliseconds, older payloads seconds.
        def created_at(job)
          created = job[CREATED_AT].to_f
          created > 1e11 ? created / 1000 : created
        end

        def collect(payload, into)
          job = parse(payload)
          return payload.b.split('"').each { |token| into << token } unless job.is_a?(::Hash)

          into.merge(digests(job))
        end

        def parse(payload)
          Wurk.load_json(payload)
        rescue ::JSON::ParserError, ::EncodingError
          nil
        end
      end

      # Runs the reaper every `reaper_interval` on one process: the one holding
      # `uniquejobs:reaper`, the key the gem's reaper holds, so a fleet running
      # both never reaps twice. A process that loses the key keeps trying for it,
      # so the reaper outlives the process that first ran it.
      module Manager
        DRIFT_FACTOR = 0.02
        REAPERS = %i[ruby lua].freeze

        class << self
          def enabled? = REAPERS.include?(UniqueJobs.config.reaper)

          def start
            return unless enabled?
            return @thread if @thread&.alive?

            @stop = false
            @owner = false
            @wake = ::Thread::Queue.new
            @thread = ::Thread.new { run }
            @thread.name = 'wurk-unique-jobs-reaper'
            @thread
          end

          def stop
            return unless @thread

            @stop = true
            @wake << :stop
            @thread.join(5)
            UniqueJobs.redis { |conn| conn.call('DEL', UNIQUE_REAPER) } if @owner
            @owner = false
            @thread = nil
          end

          def interval = UniqueJobs.config.reaper_interval.to_i
          def drift_interval = interval + (interval * DRIFT_FACTOR).to_i

          # One tick: hold or take the key, then reap. Returns digests deleted.
          def tick
            @owner = claim
            return 0 unless @owner

            Reaper.call
          end

          private

          def run
            until @stop
              begin
                tick
              rescue StandardError => e
                UniqueJobs.logger.warn("uniquejobs reaper: #{e.class}: #{e.message}")
              end
              # A queue, not `sleep`: a stop that lands before the wait still ends it.
              @wake.pop(timeout: interval) unless @stop
            end
          end

          def claim
            now = ::Time.now.to_i
            UniqueJobs.redis do |conn|
              if @owner
                conn.call('SET', UNIQUE_REAPER, now, 'EX', drift_interval)
                true
              else
                conn.call('SET', UNIQUE_REAPER, now, 'NX', 'EX', drift_interval) == 'OK'
              end
            end
          end
        end
      end
    end
  end
end
