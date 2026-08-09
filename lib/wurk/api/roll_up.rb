# frozen_string_literal: true

require_relative 'serializers'

module Wurk
  module API
    # `GET /swarm`: many heartbeats folded into one answer to "how is the
    # swarm actually working". Serializers shapes one process; this shapes the
    # cluster, and it is the only place the two differ in kind.
    #
    # A pure function of the {Wurk::Process} list it is handed — no Redis of
    # its own — so the roll-up and the `/processes` listing beside it can only
    # ever describe the same fleet.
    #
    # What it deliberately does not report: the swarm parent's rolling-restart
    # state. `Wurk::Swarm::Restart` is a state machine in the parent's memory —
    # which slot is being replaced, whether its replacement has beaten yet —
    # and no part of it is ever written to Redis. The API usually runs in a
    # different process entirely (a Rails web worker, or standalone `wurk
    # api`), so the only way to serve it would be new heartbeat traffic, which
    # is exactly what this plane may not add. The observable signature is here
    # instead: `versions` holds more than one entry while a deploy is
    # mid-flight, `processes.quiet` counts the children already told to drain,
    # and `hosts` shows the per-host child count the replacements land in.
    module RollUp
      module_function

      # @param processes [Array<Wurk::Process>] live heartbeats, already
      #   filtered of identities whose `info` has expired (ProcessSet#each).
      # @param leader_identity [String] the `dear-leader` value, read once.
      # @param now [Float] epoch seconds, taken once for the whole answer.
      def cluster(processes, leader_identity:, now:)
        ages = processes.map { |process| Serializers.beat_age_seconds(process['beat'], now) }
        {
          processes: process_counts(processes, ages),
          **totals(processes),
          queues: processes.flat_map(&:queues).compact.uniq.sort,
          versions: processes.filter_map(&:version).uniq.sort,
          leader: leader(processes, leader_identity),
          hosts: hosts(processes),
          slots: slots(processes),
          beat: beat(ages)
        }
      end

      def totals(processes)
        concurrency = sum(processes, 'concurrency')
        busy = sum(processes, 'busy')
        {
          concurrency: concurrency, busy: busy,
          utilization: utilization(busy, concurrency), rss_kb: sum(processes, 'rss')
        }
      end

      def sum(processes, field) = processes.sum { |process| process[field].to_i }

      def process_counts(processes, ages)
        {
          total: processes.size,
          quiet: processes.count(&:stopping?),
          stale: ages.count { |age| Serializers.stale?(age) }
        }
      end

      # Busy threads over total threads, as a fraction. Zero rather than a
      # division by zero when nothing is running: an empty fleet is 0% busy,
      # and a null here would only push the special case onto every client.
      def utilization(busy, concurrency)
        return 0.0 if concurrency.zero?

        (busy.to_f / concurrency).round(4)
      end

      # `live` distinguishes a leader that is still beating from a lock left
      # behind by a process that died holding it — the key outlives the
      # heartbeat by up to its own TTL, and during that gap the cluster has a
      # recorded leader and no leader.
      def leader(processes, identity)
        identity = identity.to_s
        return { identity: nil, live: false } if identity.empty?

        { identity: identity, live: processes.any? { |process| process.identity == identity } }
      end

      # Per-host roll-up, which is what "how many children is this box
      # running" actually asks. Hardware facts ride here rather than on every
      # process row: they describe the box, and repeating them per child would
      # invite a client to average them.
      def hosts(processes)
        grouped = processes.group_by { |process| process['hostname'] }
        grouped.map { |hostname, group| host(hostname, group) }.sort_by { |host| host[:hostname].to_s }
      end

      def host(hostname, group)
        facts = group.first
        {
          hostname: hostname, processes: group.size,
          concurrency: sum(group, 'concurrency'), busy: sum(group, 'busy'), rss_kb: sum(group, 'rss'),
          cpu_model: facts['cpu_model'], cores: facts['cores'], memory_total_kb: facts['memory_total_kb']
        }
      end

      # The topology as the heartbeats describe it, in {Wurk::Topology::Slot}'s
      # own vocabulary: how many children of each (queues, concurrency) kind
      # are live. Observed rather than read off `config.topology`, because the
      # declaration lives in the swarm parent's configuration and the process
      # answering this request may not share it — a standalone `wurk api` would
      # otherwise report a slot table derived from its own CPU count, which
      # describes nothing that is running.
      def slots(processes)
        grouped = processes.group_by { |process| [process.queues.to_a.sort, process['concurrency'].to_i] }
        rows = grouped.map do |(queues, concurrency), group|
          { count: group.size, queues: queues, concurrency: concurrency }
        end
        rows.sort_by { |slot| [-slot[:count], slot[:queues]] }
      end

      # The oldest beat is the one that says whether anything has gone quiet on
      # the wire; the threshold ships with it so a client reads the verdict and
      # the rule behind it in the same document.
      def beat(ages)
        { oldest_age_seconds: ages.max, stale_after_seconds: Serializers::STALE_AFTER_SECONDS }
      end
    end
  end
end
