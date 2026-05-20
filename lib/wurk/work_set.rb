# frozen_string_literal: true

module Wurk
  # Live snapshot of currently-executing jobs across the cluster. Reads
  # `<identity>:work` HASH per registered process; each field is a thread
  # id → JSON payload. The data lags reality by up to one heartbeat (10s)
  # since heartbeats `UNLINK` and rewrite the hash atomically.
  #
  # Wire-compat is sacred — every Redis call matches Sidekiq OSS exactly.
  # Spec: docs/target/sidekiq-free.md §19.7.
  class WorkSet
    include Enumerable

    # Pipelined `<identity>:work` HGETALL per known process. Yields
    # (process_id, thread_id, Work). Result sorted by `run_at` so the
    # oldest in-flight job appears first — dashboards rely on this order.
    def each
      return enum_for(:each) unless block_given?

      collect_rows.sort_by { |(_, _, work)| work.run_at }.each { |row| yield(*row) }
    end

    # Sum of `busy` HASH field across every known identity. Lagged by one
    # heartbeat. Pipelined HGET — unbounded by process count but each
    # call is O(1) on the Redis side.
    def size
      Wurk.redis do |conn|
        procs = conn.call('SMEMBERS', Keys::PROCESSES)
        next 0 if procs.empty?

        conn.pipelined do |pipe|
          procs.each { |key| pipe.call('HGET', key, 'busy') }
        end.sum(&:to_i)
      end
    end

    # O(n) scan for a JID across all in-flight jobs. Returns nil when no
    # match. Slow — not for app logic. Aliased as `find_work_by_jid` for
    # Sidekiq wire-compat.
    def find_work(jid)
      each do |_process_id, _thread_id, work|
        return work if work.job.jid == jid
      end
      nil
    end
    alias find_work_by_jid find_work

    private

    def collect_rows
      procs, all_works = fetch_work_hashes
      procs.zip(all_works).flat_map do |key, workers|
        rows_for(key, workers)
      end
    end

    def fetch_work_hashes
      Wurk.redis do |conn|
        ids = conn.call('SMEMBERS', Keys::PROCESSES).sort
        next [[], []] if ids.empty?

        works = conn.pipelined do |pipe|
          ids.each { |id| pipe.call('HGETALL', "#{id}:work") }
        end
        [ids, works]
      end
    end

    def rows_for(key, workers)
      workers.filter_map do |tid, json|
        next nil if json.nil? || json.empty?

        [key, tid, Work.new(key, tid, Wurk.load_json(json))]
      end
    end
  end

  # One in-flight job. The `payload` field is the raw JSON the processor
  # is currently executing; `job` lazily wraps it in a JobRecord so
  # downstream code can read class/args/jid without re-parsing.
  #
  # Spec: docs/target/sidekiq-free.md §19.7.
  class Work
    attr_reader :process_id, :thread_id

    def initialize(pid, tid, hsh)
      @process_id = pid
      @thread_id = tid
      @hsh = hsh
    end

    def queue   = @hsh['queue']
    def payload = @hsh['payload']

    # Float epoch seconds → Time. Heartbeat writes `run_at` as Float, so
    # we don't have to handle the dual ms/secs format JobRecord does.
    def run_at
      ::Time.at(@hsh['run_at'])
    end

    def job
      @job ||= JobRecord.new(payload)
    end
  end

  # Deprecated alias. Sidekiq <8 used `Workers` for what is now `WorkSet`;
  # third-party gems may still reference it. Resolved at load time so
  # the alias survives a constant lookup by either name.
  Workers = WorkSet
end
