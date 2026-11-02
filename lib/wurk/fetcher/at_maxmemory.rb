# frozen_string_literal: true

require_relative 'oom_drain'

module Wurk
  class Fetcher
    # {Fetcher::Reliable}'s fetch once Redis has refused one with OOM: a full
    # Redis refuses LMOVE, which would stop every worker draining the queues that
    # filled it. See OomDrain for what makes this possible. Only reached after an
    # OutOfMemoryError, so it costs a healthy fetch nothing.
    module AtMaxmemory
      # Seconds between error reports while draining a full Redis. Every thread
      # lands here on every fetch for as long as it lasts.
      REPORT_INTERVAL = 60

      private

      # Costs the wall clock a BLMOVE would have on an empty pass, for the reason
      # #retrieve_work's short-circuits do. An ACK is an LREM, which a full Redis
      # still takes.
      def claim_at_maxmemory(queues, error)
        flush_pending_acks
        report_maxmemory(error)
        fetchable = fetchable_at_maxmemory(queues)
        raise error if fetchable.empty?

        index, job = claim_past_maxmemory(fetchable, error)
        return unit_at_maxmemory(fetchable[index - 1], job) if job

        sleep poll_interval
        nil
      end

      # A pipeline applies everything it can before raising; the guard makes what
      # already went back a no-op here.
      def requeue_past_maxmemory(units, error)
        config.redis(idempotent: true) do |conn|
          units.each { |uow| OomDrain.requeue(conn, error, queue_keys(uow.queue).first, uow.queue, uow.job) }
        end
      end

      def claim_past_maxmemory(fetchable, error)
        keys = fetchable.flat_map { |public_q| [public_q, queue_keys(public_q).first] }
        config.redis(idempotent: true) do |conn|
          OomDrain.claim(conn, error, keys: keys, info: maxmemory_info, beat: ::Time.now.to_f.to_s)
        end
      end

      def unit_at_maxmemory(public_q, job)
        priv, name = queue_keys(public_q)
        unit_of_work(public_q, priv, name, job)
      end

      # Capped overrides this: a cap cannot be honoured by a script that skips
      # the ledger's write.
      def fetchable_at_maxmemory(queues)
        queues
      end

      # What the claim script writes if this process has no heartbeat hash (it
      # booted into the full Redis). The first ordinary beat replaces it.
      def maxmemory_info
        Wurk.dump_json(
          'hostname' => hostname, 'pid' => ::Process.pid, 'identity' => Component.identity,
          'started_at' => ::Time.now.to_f, 'tag' => '', 'labels' => [], 'concurrency' => config.concurrency,
          'queues' => config.queues.uniq, 'version' => Wurk::VERSION, 'embedded' => false
        )
      end

      def report_maxmemory(error)
        now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        return if @oom_reported_at && now - @oom_reported_at < REPORT_INTERVAL

        @oom_reported_at = now
        handle_exception(error, { context: 'Redis is at maxmemory: draining with allow-oom scripts' })
      end
    end
  end
end
