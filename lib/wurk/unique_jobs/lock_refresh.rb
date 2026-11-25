# frozen_string_literal: true

module Wurk
  module UniqueJobs
    # `UniqueJobs.refresh_lock!`: pushes out the TTL of the lock a running job
    # still holds, so a `perform` that can outlast any sane `lock_ttl` keeps its
    # lock by renewing it instead of by a TTL long enough to cover the slowest
    # run (which a crashed run then holds for just as long). Wurk only: the gem
    # sets a lock's TTL once, when the lock is taken.
    #
    # One script (`unique_jobs_refresh.lua`) checks that this run (see Run) still
    # holds the lock and only then re-applies the expiry; it never takes a lock, so
    # a refresh that comes too late, or from a run a later one of the same jid
    # superseded, returns false and the caller decides what that means for it.
    class LockRefresh
      # The types whose lock during `perform` is the runtime one, `<digest>:RUN`.
      # until_and_while_executing gave up its push lock when `perform` started.
      RUNTIME_LOCKS = [Lock::WhileExecuting, Lock::UntilAndWhileExecuting].freeze

      def initialize(job, ttl: nil)
        @item = item_for(job)
        @pttl = pttl_for(ttl)
      end

      def call
        UniqueJobs.redis do |conn|
          Script.call(:unique_jobs_refresh, conn, keys: key.to_a,
                                                  argv: [@item[JID], @pttl, UniqueJobs.now_f, run_token])
        end == 1
      end

      private

      def item_for(job)
        item = case job
               when ::Hash then job
               when ::String then running(Run.of_jid(job), job)
               else
                 raise ::ArgumentError, "expected a job payload, a jid or a job instance, got #{job.inspect}" \
                   unless job.class.respond_to?(:get_sidekiq_options)

                 running(Run.of_worker(job) || Run.of_jid(job.jid), job.jid)
               end
        [JID, LOCK, LOCK_DIGEST].each do |field|
          raise ::ArgumentError, "not a unique job payload: no `#{field}` in #{item.inspect}" unless item[field]
        end
        item
      end

      def running(run, jid)
        return run.item if run

        raise ::ArgumentError, "no job #{jid.inspect} is running under a Wurk::UniqueJobs lock in this process; " \
                               'refresh_lock! by jid works only inside its perform (or a thread it started)'
      end

      # A payload that is not the running job's own object is known by jid only:
      # the run of that jid here answers for it, and a payload that runs nowhere
      # in this process renews by jid.
      def run_token
        marks = Run.marks_of(@item) || Run.of_jid(@item[JID])&.marks
        marks&.fetch(key.digest, nil).to_s
      end

      # Seconds, from the caller or else the TTL the lock was taken with: the
      # `lock_ttl` the payload carries. 0 means the lock never expires, so a
      # refresh only answers whether it is still held.
      def pttl_for(ttl)
        return LockConfig.new(@item).pttl if ttl.nil?
        raise ::ArgumentError, "ttl must be a positive number of seconds, got #{ttl.inspect}" \
          unless ttl.is_a?(::Numeric) && (ttl * 1_000).to_i.positive?

        (ttl * 1_000).to_i
      end

      def key
        digest = @item[LOCK_DIGEST]
        runtime = RUNTIME_LOCKS.any? { |klass| lock_class <= klass }
        Key.new(runtime && !digest.end_with?(RUN_SUFFIX) ? "#{digest}#{RUN_SUFFIX}" : digest)
      end

      def lock_class
        type = @item[LOCK].to_sym
        UniqueJobs.locks.fetch(type) { raise UnknownLock, "No implementation for `lock: :#{type}`" }
      end
    end
  end
end
