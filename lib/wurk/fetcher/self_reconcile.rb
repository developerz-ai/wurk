# frozen_string_literal: true

require_relative '../keys'
require_relative 'orphan_reclaim'

module Wurk
  class Fetcher
    # A live worker's check of its own private lists.
    #
    # The Reaper leaves a live owner's list alone, and a live owner only ever
    # settles the jobs its threads know about. So a payload no thread knows about
    # would wait there until the process exits. Two ways in:
    #   * a claim applied but its reply was lost (Redis restart, a stall past the
    #     read timeout, a dropped socket): the client re-sends and claims another
    #     job, so one job per thread per incident;
    #   * a job that failed while Redis was down, where the retry booking and the
    #     requeue both raised.
    #
    # A payload counts as stranded only if it is in the list and held by nothing:
    # no thread's claim (Fetcher::Reliable::CLAIM_KEY, which covers the whole of
    # a running job however long it runs) and no pending ACK. The list is read
    # first and the holders second, so a claim landing between the two reads as
    # held. What the reads cannot see is a unit in transit: claimed but not yet
    # stamped, or an ACK on the wire. Those last microseconds to seconds, which
    # is why one sighting proves nothing: it has to be seen stranded again at
    # least `confirm` seconds later before it moves.
    #
    # Counted rather than compared as sets, because a client re-send can leave two
    # byte-identical payloads, and a running job must not vouch for its twin.
    class SelfReconcile
      # Above anything a unit can spend in transit: the longest a held ACK sits on
      # the wire is the pool's blip backoff plus its socket timeouts, ~18s.
      DEFAULT_CONFIRM = 30

      Suspect = Struct.new(:copies, :since)

      # A payload put back goes through the same poison accounting as a reclaim
      # (OrphanReclaim), so a job that kills its processor thread every time
      # still hits the poison cap.
      def initialize(config, confirm: DEFAULT_CONFIRM, stop: -> { false })
        @config = config
        @confirm = confirm
        @stop = stop
        @orphan_reclaim = OrphanReclaim.new(config)
        @suspects = {}
      end

      # One pass. Returns how many payloads went back to their public queues.
      def sweep
        lists = own_lists
        return 0 if lists.empty?

        crowded = crowded_lists(lists)
        return forget_all if crowded.empty?

        contents = read(crowded.keys)
        settle(crowded, contents, held_by_list)
      end

      private

      # { private_list => public_queue } for every queue a Reliable fetcher here
      # serves. Two capsules on one queue share a list, hence the Hash. A custom
      # `config[:fetch_class]` keeps its own books, so its queues are left alone.
      def own_lists
        @config.capsules.each_value.with_object({}) do |capsule, lists|
          next unless capsule.fetcher.is_a?(Reliable)

          capsule.queues.uniq.each do |name|
            lists[Reliable.private_queue_name(Keys.queue(name))] = Keys.queue(name)
          end
        end
      end

      # A list no longer than what its holders account for has nothing stranded
      # in it, which is every list on every healthy sweep, and LLEN is what keeps
      # a healthy sweep from reading every in-flight payload back over the wire.
      def crowded_lists(lists)
        lengths = read_lengths(lists.keys)
        held = held_by_list
        lists.select { |list, _| lengths[list] > held_count(held, list) }
      end

      def read_lengths(names)
        replies = @config.redis(idempotent: true) do |conn|
          conn.pipelined { |pipe| names.each { |list| pipe.call('LLEN', list) } }
        end
        names.zip(replies).to_h
      end

      def held_count(held, list)
        held.fetch(list, {}).each_value.sum
      end

      def read(names)
        replies = @config.redis(idempotent: true) do |conn|
          conn.pipelined { |pipe| names.each { |list| pipe.call('LRANGE', list, 0, -1) } }
        end
        names.zip(replies).to_h
      end

      # { private_list => { payload => count } } across every thread and fetcher
      # in this process. Thread.list, not a registry: nothing is written per job,
      # and a thread that died mid-job stops vouching for its payload by itself.
      def held_by_list
        held_units.each_with_object({}) do |unit, held|
          tally = (held[unit.private_queue] ||= Hash.new(0))
          tally[unit.job.b] += 1
        end
      end

      def held_units
        claims = ::Thread.list.filter_map { |thread| thread.thread_variable_get(Reliable::CLAIM_KEY) }
        fetchers = @config.capsules.each_value.map(&:fetcher).grep(Reliable)
        claims + fetchers.flat_map(&:held_acks)
      end

      def settle(crowded, contents, held)
        now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        following = {}
        moved = contents.sum do |list, payloads|
          stranded(payloads, held[list]).sum do |payload, count|
            judge(list, crowded[list], payload, count, now, following)
          end
        end
        @suspects = following
        moved
      end

      # Moves what has been seen stranded for long enough, remembers the rest.
      def judge(list, public_q, payload, count, now, following) # rubocop:disable Metrics/ParameterLists
        suspect = @suspects.dig(list, payload)
        confirmed = suspect && now - suspect.since >= @confirm
        return put_back(list, public_q, payload, [count, suspect.copies].min) if confirmed

        (following[list] ||= {})[payload] = Suspect.new(count, suspect&.since || now)
        0
      end

      def stranded(payloads, held)
        held ||= {}
        payloads.map(&:b).tally.filter_map do |payload, count|
          excess = count - held.fetch(payload, 0)
          [payload, excess] if excess.positive?
        end
      end

      def put_back(list, public_q, payload, count)
        moved = 0
        count.times do
          break if @stop.call

          moved += requeue(list, public_q, payload)
        end
        moved
      end

      # LPOS-guarded, so a payload settled since the last read stays settled.
      def requeue(list, public_q, payload)
        @orphan_reclaim.call(list, public_q, payload) ? 1 : 0
      end

      def forget_all
        @suspects = {}
        0
      end
    end
  end
end
