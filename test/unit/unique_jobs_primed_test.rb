# frozen_string_literal: true

require_relative '../test_helper'

# `<digest>:PRIMED` is the hand-off list of the blocking lock path: BLMOVE moves
# a waiter's entry (or an unlock's "1") there from QUEUED, and the lock script
# takes it out. Nothing gave it a TTL, so an entry the lock script never took
# out stayed for good: a run killed or interrupted between the two, or a lock
# script that found the lock taken meanwhile. A production Dragonfly held 130
# `<digest>:RUN:PRIMED` lists that way. Each case runs the steps the Locksmith
# runs, in the order that strands the entry.
class UniqueJobsPrimedTest < Wurk::Test::UnitCase
  def setup
    super
    Wurk::UniqueJobs.reset!
    @digest = "uniquejobs:primed-#{SecureRandom.hex(6)}:RUN"
  end

  def teardown
    Wurk.redis { |c| c.call('DEL', *%w[QUEUED PRIMED LOCKED INFO].map { |s| "#{@digest}:#{s}" }, @digest) }
    Wurk::UniqueJobs.reset!
  ensure
    super
  end

  def smith(jid = SecureRandom.hex(12))
    item = { 'jid' => jid, 'class' => 'X', 'queue' => 'default', 'lock' => 'while_executing',
             'lock_digest' => @digest, 'lock_ttl' => 0, 'lock_timeout' => 1 }
    Wurk::UniqueJobs::Locksmith.new(item)
  end

  def primed = "#{@digest}:PRIMED"
  def ttl(key) = Wurk.redis { |c| c.call('PTTL', key) }
  def entries(key) = Wurk.redis { |c| c.call('LRANGE', key, 0, -1) }

  # The run dies after BLMOVE, before the lock script: its entry is left.
  def test_an_entry_a_run_left_after_the_hand_off_expires
    waiter = smith
    Wurk::UniqueJobs.redis do |conn|
      waiter.send(:run_script, :unique_jobs_queue, conn, waiter.send(:argv))
      waiter.send(:pop_queued, conn, 1)
    end

    assert_equal [waiter.job_id], entries(primed)
    assert_operator ttl(primed), :>, 0, 'a PRIMED list with no TTL outlives the run that made it'
  end

  # The TTL rides the same pipeline as the move, so the server sets it right
  # after serving the move whether or not this process lives to read the reply.
  # A PEXPIRE sent after reading it would leave the window open.
  def test_the_move_and_its_ttl_go_in_one_pipeline
    conn = RecordingConn.new

    smith.send(:pop_queued, conn, 1)

    assert_equal [%w[pipeline BLMOVE], %w[pipeline PEXPIRE]], conn.log
  end

  # Another job took the lock between this run's BLMOVE and its lock script, so
  # the script answers "Limited". The wake token it moved must not stay behind.
  def test_a_limited_lock_script_takes_its_hand_off_back_out
    holder = smith
    waiter = smith
    Wurk.redis do |c|
      c.call('HSET', "#{@digest}:LOCKED", holder.job_id, Wurk::UniqueJobs.now_f)
      c.call('LPUSH', primed, '1')
    end

    jid = Wurk::UniqueJobs.redis { |conn| waiter.send(:run_script, :unique_jobs_lock, conn, waiter.send(:argv) + ['']) }

    assert_nil jid
    assert_empty entries(primed)
    assert_equal([holder.job_id], Wurk.redis { |c| c.call('HKEYS', "#{@digest}:LOCKED") })
  end

  # A pop that took another waiter's entry (a lock_limit above 1) does not run
  # the lock script; the entry it moved expires instead of staying for good.
  def test_a_pop_of_another_waiters_entry_expires
    waiter = smith
    other = smith
    Wurk.redis { |c| c.call('LPUSH', "#{@digest}:QUEUED", other.job_id) }

    refute(Wurk::UniqueJobs.redis { |conn| waiter.send(:primed?, conn, 1) })
    assert_operator ttl(primed), :>, 0
  end

  def test_the_whole_blocking_path_leaves_nothing
    waiter = smith
    ran = waiter.execute { :ran }

    assert_equal :ran, ran
    assert_empty entries(primed)
    waiter.unlock

    assert_empty(Wurk.redis { |c| c.call('KEYS', "#{@digest}*") }.reject { |k| k.end_with?(':QUEUED') })
  end

  # Records which commands a Locksmith sends, and whether inside a pipeline.
  class RecordingConn
    attr_reader :log

    def initialize
      @log = []
    end

    def pipelined
      yield Pipe.new(@log)
      [nil, 0]
    end

    def blocking_call(_timeout, *command) = @log << ['direct', command.first]
    def call(*command) = @log << ['direct', command.first]

    Pipe = ::Struct.new(:log) do
      def blocking_call(_timeout, *command) = log << ['pipeline', command.first]
      def call(*command) = log << ['pipeline', command.first]
    end
  end
end
