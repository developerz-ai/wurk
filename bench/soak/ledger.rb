# frozen_string_literal: true

module WurkSoak
  # The jid ledger (plan 101/12 T1): an append-only file, not Redis, so a Redis
  # restart cannot rewrite the evidence. One tab-separated line per event:
  #
  #   event  wall-time  pid  id  kind  extra
  #
  # Events: push / push_err / halted (producer, after the client returned,
  # raised, or returned nil), uniq_rej / uniq_leak (a deliberate duplicate the
  # unique lock refused, or let through), batch / batch_err,
  # run / done / drop (server middleware around perform), cb (a batch callback
  # body), and chaos / outage_start / outage_end (the chaos loop).
  #
  # Each process holds one O_APPEND descriptor and writes a whole line per
  # syswrite, so lines from concurrent processes never interleave.
  module Ledger
    WINDOWS = {
      'deferred_ack' => 'docs/reliability.md#the-ack-rides-the-next-fetch',
      'scheduler_lease' => 'docs/reliability.md#the-reliable-scheduler',
      'redis_outage' => 'docs/reliability.md#a-live-workers-own-private-list'
    }.freeze

    # Kinds that reach their queue through the `schedule`/`retry` sorted sets,
    # where the poller's 60s lease can promote a member twice.
    ZSET_KINDS = %w[scheduled retry limited unique].freeze
    SCHEDULER_LEASE = 60.0
    # How far before a first completion an outage may start and still have
    # swallowed that completion's ACK (the fetcher's read timeout, rounded up).
    OUTAGE_SLACK = 3.0

    @lock = Mutex.new

    class << self
      def path = ENV.fetch('SOAK_LEDGER')

      def record(event, ident = '-', kind = '-', extra = '-')
        line = "#{event}\t#{format('%.6f', ::Process.clock_gettime(::Process::CLOCK_REALTIME))}\t" \
               "#{::Process.pid}\t#{ident}\t#{kind}\t#{extra}\n"
        io.syswrite(line)
      end

      private

      def io
        @lock.synchronize do
          unless @pid == ::Process.pid && @io_path == path
            @io = File.open(path, File::WRONLY | File::APPEND | File::CREAT)
            @pid = ::Process.pid
            @io_path = path
          end
          @io
        end
      end
    end

    Event = Struct.new(:event, :time, :pid, :id, :kind, :extra)

    # Reads the ledger incrementally (the drain loop polls it) and keeps the
    # per-jid tallies the verdict needs.
    class Book
      attr_reader :pushes, :push_errs, :runs, :dones, :drops, :batches, :batch_errs, :callbacks, :chaos,
                  :outages, :counters

      def initialize(path)
        @path = path
        @offset = 0
        @partial = +''
        @pushes = {}
        @push_errs = {}
        @runs = Hash.new { |h, k| h[k] = [] }
        @dones = Hash.new { |h, k| h[k] = [] }
        @drops = {}
        @batches = {}
        @batch_errs = {}
        @callbacks = Hash.new { |h, k| h[k] = [] }
        @chaos = []
        @outages = []
        @counters = Hash.new(0)
      end

      def ingest!
        return self unless File.exist?(@path)

        File.open(@path) do |f|
          f.seek(@offset)
          chunk = f.read
          @offset += chunk.bytesize
          lines = (@partial + chunk).split("\n", -1)
          @partial = lines.pop || +''
          lines.each { |l| apply(parse(l)) }
        end
        self
      end

      def parse(line)
        event, time, pid, id, kind, extra = line.split("\t", 6)
        Event.new(event, time.to_f, pid.to_i, id, kind, extra)
      end

      def apply(evt) # rubocop:disable Metrics/CyclomaticComplexity
        case evt.event
        when 'push' then @pushes[evt.id] = evt
        when 'push_err' then @push_errs[evt.id] = evt
        when 'uniq_rej', 'uniq_leak', 'halted' then @counters[evt.event] += 1
        when 'batch' then @batches[evt.id] = evt
        when 'batch_err' then @batch_errs[evt.id] = evt
        when 'run' then @runs[evt.id] << evt
        when 'done' then @dones[evt.id] << evt
        when 'drop' then @drops[evt.id] = evt
        when 'cb' then @callbacks[evt.id] << evt
        when 'chaos' then @chaos << evt
        when 'outage_start' then @outages << [evt.time, nil]
        when 'outage_end' then @outages.last[1] = evt.time if @outages.last
        end
      end

      # Pushed jids with no completion yet, and batches whose :success has not
      # run. The drain loop waits for both to empty.
      def pending_jids = @pushes.keys.reject { |jid| @dones.key?(jid) }
      def pending_batches = @batches.keys.reject { |bid| @callbacks.key?(bid) }
    end

    # Judges a fully ingested Book. `dead` maps jid => error_message for every
    # job in the dead set, read after the drain.
    class Verdict
      def initialize(book, dead: {})
        @book = book
        @dead = dead
      end

      def to_h
        lost, dead = @book.pending_jids.partition { |jid| !@dead.key?(jid) }
        dups = duplicates
        {
          balanced: balanced?(lost, dups),
          pushed: @book.pushes.size, completed: @book.pushes.keys.count { |j| @book.dones.key?(j) },
          lost: lost.sort, dead: dead.to_h { |j| [j, @dead[j]] },
          duplicates: dups, reruns: reruns, unledgered: unledgered,
          push_errors: { total: @book.push_errs.size,
                         accepted_anyway: @book.push_errs.keys.count { |j| @book.dones.key?(j) } },
          unique: { rejected: @book.counters['uniq_rej'], leaked: @book.counters['uniq_leak'] },
          halted_pushes: @book.counters['halted'], lossy_drops: @book.drops.size,
          cron: cron_report, batches: batch_report, chaos: chaos_counts
        }
      end

      private

      # A leaked unique push is a broken lock and an out-of-order callback a
      # broken batch promise; neither is an at-least-once window.
      def balanced?(lost, dups)
        lost.empty? && dups[:unattributed].empty? && unledgered.empty? && batch_report[:missing].empty? &&
          batch_report[:out_of_order].empty? && @book.counters['uniq_leak'].zero?
      end

      # A jid completed more than once, each extra completion explained by a
      # documented at-least-once window or listed as unattributed.
      def duplicates
        by_window = Hash.new(0)
        unattributed = []
        each_duplicate do |id, first, again, kind|
          window = attribute(first, again, kind)
          window ? by_window[window] += 1 : unattributed << id
        end
        { by_window: by_window.to_h { |w, n| [w, { count: n, doc: WINDOWS.fetch(w) }] },
          unattributed: unattributed.sort }
      end

      def each_duplicate(&)
        @book.dones.each do |jid, dones|
          dones.each_cons(2) { |a, b| yield jid, a, b, a.kind }
        end
        @book.callbacks.each do |bid, cbs|
          cbs.each_cons(2) { |a, b| yield bid, a, b, 'callback' }
        end
      end

      def attribute(first, again, kind)
        return 'deferred_ack' if killed_between?(first, again)
        return 'redis_outage' if outage_between?(first.time - OUTAGE_SLACK, again.time)
        return 'scheduler_lease' if ZSET_KINDS.include?(kind) && kill_between?(first.time - SCHEDULER_LEASE, again.time)

        nil
      end

      # The process that completed it was SIGKILLed before the job completed
      # again: the ACK rode the next fetch and died with it. A kill after the
      # second completion cannot have caused it.
      def killed_between?(first, again)
        @book.chaos.any? do |c|
          c.kind == 'kill9' && c.id.to_i == first.pid && c.time.between?(first.time, again.time)
        end
      end

      def kill_between?(from, upto)
        @book.chaos.any? { |c| %w[kill9 parent_kill9].include?(c.kind) && c.time.between?(from, upto) }
      end

      def outage_between?(from, upto)
        @book.outages.any? { |s, e| s <= upto && (e.nil? || e >= from) }
      end

      # Started again after an attempt that did not complete: a mid-perform kill,
      # a graceful requeue, an iterable interruption, a retry or a limiter
      # reschedule. All legal; counted so a run can show the chaos bit.
      def reruns
        @book.runs.sum { |_, runs| [runs.size - 1, 0].max }
      end

      # A run nobody pushed: not producer-ledgered, not a cron fire, not a push
      # that raised yet landed. Should be empty.
      def unledgered
        @unledgered ||= @book.runs.keys.reject do |jid|
          @book.pushes.key?(jid) || @book.push_errs.key?(jid) || @book.runs[jid].first.kind == 'cron'
        end.sort
      end

      def cron_report
        jids = @book.runs.select { |_, runs| runs.first.kind == 'cron' }.keys
        { fired: jids.size, completed: jids.count { |j| @book.dones.key?(j) },
          completed_twice: jids.count { |j| @book.dones[j].size > 1 } }
      end

      def batch_report
        @batch_report ||= begin
          missing = @book.pending_batches
          { created: @book.batches.size, failed_to_create: @book.batch_errs.size,
            success_callbacks: @book.callbacks.size, missing: missing.sort,
            out_of_order: out_of_order_parents }
        end
      end

      # A parent's :success ran before one of its children's.
      def out_of_order_parents
        @book.batches.values.filter_map do |child|
          parent = child.extra
          next if parent == '-' || !@book.callbacks.key?(parent) || !@book.callbacks.key?(child.id)

          parent if @book.callbacks[parent].first.time < @book.callbacks[child.id].first.time
        end.uniq.sort
      end

      def chaos_counts
        @book.chaos.group_by(&:kind).transform_values(&:size)
      end
    end
  end
end
