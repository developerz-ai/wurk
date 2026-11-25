# frozen_string_literal: true

require 'securerandom'

module Wurk
  module UniqueJobs
    # One execution of a unique job. A jid can be running twice: an interrupted
    # run still unwinding while its requeued payload runs elsewhere, or a process
    # cut off from Redis whose job was reclaimed. The lock admits both, since by
    # jid they are one job and crash recovery depends on it, so each run marks the
    # lock it enters with a token of its own (the value beside its jid in LOCKED)
    # and the newest mark is the holder. A run that finds another mark there has
    # been superseded: it unlocks and renews nothing.
    #
    # Tied to the payload object the run was given, never written into it: the
    # payload goes back to Redis unchanged, and whatever unlocks later with that
    # object (FinishedJobCleanup) is still this run.
    class Run
      IVAR = :@wurk_unique_run
      private_constant :IVAR

      @running = []
      @mutex = ::Mutex.new

      class << self
        # Around the server half of a lock: a new run of `item`, in #running for
        # as long as the block takes.
        def track(worker, item)
          run = new(worker, item)
          item.instance_variable_set(IVAR, run)
          @mutex.synchronize { @running << run }
          yield
        ensure
          @mutex.synchronize { @running.delete_if { |other| other.equal?(run) } }
        end

        # The run this payload object, or the one it is a #dup of, belongs to; nil
        # for one that never ran here.
        def of(item) = item.instance_variable_get(IVAR)

        def of_worker(worker) = @mutex.synchronize { @running.find { |run| run.worker.equal?(worker) } }

        # The run of `jid` on this thread, else the oldest in this process. Two at
        # once cannot be told apart from another thread, and of the two the oldest
        # is the superseded one: a holder told "no" stops and is retried, an
        # impostor told "yes" goes on beside the holder.
        def of_jid(jid)
          @mutex.synchronize do
            runs = @running.select { |run| run.item[JID] == jid }
            runs.size > 1 ? runs.find(&:here?) || runs.first : runs.first
          end
        end

        # Wire-compatible: what the gem keeps beside a jid in LOCKED is the time,
        # and its dashboard reads it back as one. This is the time too, with
        # random digits below the microsecond to make it this run's alone.
        def token = format('%.6f%09d', UniqueJobs.now_f, ::SecureRandom.random_number(10**9))
      end

      attr_reader :worker, :item

      def initialize(worker, item)
        @worker = worker
        @item = item
        @thread = ::Thread.current
        @tokens = {}
      end

      def here? = @thread.equal?(::Thread.current)

      # Minted before the script that writes it: a run killed in between must
      # still recognize its mark.
      def mark(digest) = @tokens[digest] ||= Run.token

      # nil until this run has entered the lock: what it does to any other lock
      # (the push lock of until_and_while_executing) is by jid, as in the gem.
      def token_for(digest) = @tokens[digest]
    end
  end
end
