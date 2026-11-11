# frozen_string_literal: true

require 'securerandom'
require_relative 'ledger'

module WurkSoak
  # Pushes the mixed workload at a steady rate, ledgering every jid only after
  # the client returned it. A push that raised (Redis down mid-chaos) is
  # `push_err`: it may or may not have landed, so it is never counted as lost,
  # and one that ran anyway shows up as accepted-despite-error.
  class Producer
    # kind => relative weight. Batch pushes 4 jobs in 2 nested batches.
    MIX = { plain: 30, scheduled: 10, retry: 5, unique: 10, limited: 10, iterable: 5, batch: 10, tracked: 5 }.freeze
    WORK_MS = 0..40

    def initialize(rate:, rng: Random.new)
      @rate = rate
      @rng = rng
      @stop = false
      @pushed = 0
      @kinds = MIX.flat_map { |kind, weight| [kind] * weight }
    end

    attr_reader :pushed

    def stop! = (@stop = true)

    def run
      period = 1.0 / @rate
      next_at = monotonic
      until @stop
        public_send(:"push_#{@kinds.sample(random: @rng)}")
        next_at += period
        delay = next_at - monotonic
        delay.positive? ? sleep(delay) : next_at = monotonic
      end
    end

    def push_plain = push(PlainJob, [work])
    def push_tracked = push(TrackedJob, [work])
    def push_retry = push(RetryJob, [work])
    def push_limited = push(LimitedJob, [work])
    def push_iterable = push(IterableJob, [@rng.rand(5..20), 50])
    def push_scheduled = push(ScheduledJob, [work], 'at' => Time.now.to_f + @rng.rand(1.0..15.0))

    # The same key twice: the second push must come back nil. Scheduled a few
    # seconds out, so the first cannot run, succeed and release the lock
    # before the second push tries it. A second jid that does come back is
    # ledgered as a push too, so it is still accounted for.
    def push_unique
      args = [work, SecureRandom.hex(8)]
      at = Time.now.to_f + @rng.rand(2.0..5.0)
      push(UniqueJob, args, 'at' => at)
      jid = guarded(UniqueJob) { Wurk::Client.push('class' => UniqueJob, 'args' => args, 'at' => at) }
      Ledger.record('push', jid, 'unique') if jid
      Ledger.record(jid ? 'uniq_leak' : 'uniq_rej', jid || args.last, 'unique')
    end

    # Outer batch: 2 jobs plus a nested child batch of 2. Each :success
    # callback is ledgered; the child's must run before the parent's.
    def push_batch
      jids = []
      outer = new_batch
      inner = nil
      outer.jobs do
        2.times { jids << BatchJob.perform_async(work) }
        inner = new_batch
        inner.jobs { 2.times { jids << BatchJob.perform_async(work) } }
      end
      record_batch(outer, inner, jids)
    rescue StandardError => e
      [outer, inner].compact.each { |b| Ledger.record('batch_err', b.bid, 'batch', e.class) }
    end

    private

    def new_batch
      batch = Sidekiq::Batch.new
      batch.callback_queue = QUEUE
      batch.on(:success, 'WurkSoak::Callbacks#on_success')
    end

    def push(klass, args, extra = {})
      jid = SecureRandom.hex(12)
      guarded(klass, jid) do
        # nil = client middleware halted the push; nothing was enqueued.
        if Wurk::Client.push({ 'class' => klass, 'args' => args, 'jid' => jid }.merge(extra))
          Ledger.record('push', jid, KINDS.fetch(klass.name))
          @pushed += 1
        else
          Ledger.record('halted', jid, KINDS.fetch(klass.name))
        end
      end
    end

    def guarded(klass, jid = '-')
      yield
    rescue StandardError => e
      Ledger.record('push_err', jid, KINDS.fetch(klass.name), e.class)
      nil
    end

    def record_batch(outer, inner, jids)
      Ledger.record('batch', outer.bid, 'batch', '-')
      Ledger.record('batch', inner.bid, 'batch', outer.bid)
      jids.each { |jid| Ledger.record('push', jid, 'batch') }
      @pushed += jids.size
    end

    def work = @rng.rand(WORK_MS)

    def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
