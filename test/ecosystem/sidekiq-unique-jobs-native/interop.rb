# frozen_string_literal: true

# A fleet halfway through dropping sidekiq-unique-jobs: one pod still runs the gem
# (gem_pod/Gemfile), the other Wurk's native copy (this bundle), on one Redis.
# Each pod has a client (interop/agent.rb) and a worker on its own queue. Every
# scenario takes a lock on one side and needs the other side to honor it, run
# under it, or release it. A lock either side failed to see is a duplicate push,
# which on a payments queue is a second payment.

require 'json'
require 'open3'
require 'securerandom'
require 'tmpdir'
require_relative '../redis_guard'

HARNESS = __dir__
GEM_ENV = { 'BUNDLE_GEMFILE' => File.join(HARNESS, 'gem_pod/Gemfile') }.freeze
ENV['INTEROP_POD'] = 'native'
require_relative 'interop/jobs'

module InteropDriver
  module_function

  # --- the two pods -------------------------------------------------------

  def boot
    unbundled { system(GEM_ENV, 'bundle', 'install', '--quiet', exception: true) }
    Sidekiq.redis do |conn|
      EcosystemRedisGuard.check_connection!(conn.call('CLIENT', 'INFO'))
      conn.call('FLUSHDB')
    end
    @agents = { 'gem' => agent('gem'), 'native' => agent('native') }
    @workers = %w[gem native].map { |pod| worker(pod) }
    wait('both workers up') { Sidekiq::ProcessSet.new.size == 2 }
    check(ask('gem', 'op' => 'implementation') == 'SidekiqUniqueJobs', 'the gem pod is not running the gem')
    check(ask('native', 'op' => 'implementation') == 'Wurk::UniqueJobs', 'the native pod is not running Wurk')
  end

  # Each pod is its own `bundle exec`, from the environment this one started in:
  # BUNDLE_PATH and the Redis URL carry over, this bundle's RUBYOPT does not.
  def unbundled(&) = Bundler.with_original_env(&)

  def pod_env(pod)
    env = { 'BUNDLE_GEMFILE' => ENV.fetch('BUNDLE_GEMFILE'), 'INTEROP_POD' => pod }
    pod == 'gem' ? env.merge(GEM_ENV) : env
  end

  def agent(pod)
    stdin, stdout, thread = unbundled do
      Open3.popen2(pod_env(pod), 'bundle', 'exec', 'ruby', File.join(HARNESS, 'interop/agent.rb'))
    end
    { in: stdin, out: stdout, thread: thread }
  end

  def worker(pod)
    log = File.join(Dir.tmpdir, "interop-#{pod}-#{Process.pid}.log")
    pid = unbundled do
      Process.spawn(pod_env(pod).merge('WURK_COUNT' => '1'), 'bundle', 'exec', 'sidekiq',
                    '-r', File.join(HARNESS, 'interop/jobs.rb'), '-q', pod, '-c', '4',
                    out: log, err: log, pgroup: true)
    end
    { pid: pid, log: log, pod: pod }
  end

  def ask(pod, command)
    agent = @agents.fetch(pod)
    agent[:in].puts(JSON.generate(command))
    line = agent[:out].gets until line&.start_with?('REPLY ') || (line.nil? && agent[:out].eof?)
    raise "interop: the #{pod} agent died" unless line

    reply = JSON.parse(line.delete_prefix('REPLY '))
    raise "interop: #{pod} agent: #{reply['error']}" if reply.key?('error')

    reply['ok']
  end

  def push(pod, klass, args, queue:, delay: nil)
    ask(pod, 'op' => 'push', 'class' => klass.name, 'args' => args, 'queue' => queue, 'in' => delay)
  end

  def shutdown
    @workers&.each do |w|
      Process.kill('TERM', -w[:pid])
      Process.wait(w[:pid])
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    @agents&.each_value { |a| a[:in].close }
  end

  def dump_logs = @workers&.each { |w| warn("--- #{w[:pod]} worker\n#{File.read(w[:log]).lines.last(30).join}") }

  # --- scenarios ----------------------------------------------------------

  # The fields every lock reads, from the same payload, in both pods.
  def same_digests
    items = [
      ['InteropDigests::ProcArgsJob', [1, { 'id' => 7, 'at' => 'x' }]],
      ['InteropDigests::SymbolArgsJob', ['a', 2, 3.5, nil]],
      ['InteropDigests::ImplicitArgsMethodJob', [1, 'ünïcode', { 'k' => [1, 2] }]],
      ['InteropDigests::AllArgsJob', [{ 'b' => 1, 'a' => 2 }, true, 10**20]],
      ['InteropDigests::AcrossQueuesJob', [3]],
      ['InteropDigests::AcrossWorkersJob', [3]],
      ['InteropDigests::PrefixJob', [3, 4]],
      ['InteropDigests::StringMethodJob', [5, 6]],
      ['InteropUntilExecutedJob', %w[run tag]],
      ['NotLoadedAnywhereJob', [1, 2]]
    ]
    items.each_with_index do |(klass, args), i|
      %w[default critical].each do |queue|
        item = { 'class' => klass, 'queue' => queue, 'args' => args, 'jid' => "jid#{i}" }
        item['apartment'] = 'tenant' if i.even?
        gem = ask('gem', 'op' => 'prepare', 'item' => item)
        native = ask('native', 'op' => 'prepare', 'item' => item)
        check(gem == native, "lock fields differ for #{klass} on #{queue}:\n  gem:    #{gem}\n  native: #{native}")
      end
    end
  end

  # A lock taken by one pod's client refuses the other pod's push, both ways, and
  # the refused push goes to the dead set (`on_conflict: :reject`).
  def push_locks_hold_across_pods
    [%w[gem native], %w[native gem]].each do |holder, other|
      run = fresh
      check(push(holder, InteropUntilExecutedJob, [run, 'a'], queue: 'parked'), "#{holder}: first push refused")
      dead_before = Sidekiq::DeadSet.new.size
      check(push(other, InteropUntilExecutedJob, [run, 'b'], queue: 'parked').nil?,
            "#{other} pushed a duplicate of a job #{holder} had locked")
      check(Sidekiq::DeadSet.new.size == dead_before + 1, "#{other}: the rejected duplicate is not in the dead set")
      check(push(other, InteropUntilExecutedJob, [fresh, 'b'], queue: 'parked'), "#{other}: other lock args refused")
    end
  end

  # A job pushed (and locked) by one pod, run by the other pod's worker: it runs
  # once, under the lock, which is gone when it finishes.
  def runs_and_releases_across_pods
    [%w[gem native], %w[native gem]].each do |pusher, runner|
      run = fresh
      check(push(pusher, InteropUntilExecutedJob, [run, 'hold'], queue: runner), "#{pusher}: push refused")
      wait("#{runner} runs #{pusher}'s job") { started(run).any? }
      check(started(run).map { |e| e['pod'] } == [runner], "#{pusher}'s job ran on the wrong pod")
      check(push(pusher, InteropUntilExecutedJob, [run, 'again'], queue: runner).nil?,
            "#{pusher} pushed again while #{runner} ran under the lock")
      Interop.release(run)
      wait("#{runner} finishes") { Interop.events(run, 'finish').any? }
      locks_gone
      check(push(pusher, InteropUntilExecutedJob, [run, 'after'], queue: runner), 'lock survived the run')
      wait('the push after the run ran') { Interop.events(run, 'finish').size == 2 }
    end
  end

  # while_executing + reschedule: the copy meeting the other pod's running one
  # goes back through the schedule and runs after it, never beside it.
  def while_executing_reschedules_across_pods
    [%w[gem native], %w[native gem]].each do |first, second|
      run = fresh
      push(first, InteropWhileExecutingJob, [run, 'first'], queue: first)
      wait("#{first} runs the first copy") { started(run).any? }
      push(second, InteropWhileExecutingJob, [run, 'second'], queue: second)
      wait('the second copy rescheduled') { Sidekiq::ScheduledSet.new.any? { |job| job.args == [run, 'second'] } }
      check(started(run).size == 1, 'the second copy ran beside the first')
      Interop.release(run)
      wait('the second copy ran') { Interop.events(run, 'finish').size == 2 }
      finish_first = Interop.events(run, 'finish').find { |e| e['tag'] == 'first' }['at']
      start_second = started(run).find { |e| e['tag'] == 'second' }['at']
      check(start_second >= finish_first, 'the rescheduled copy overlapped the first')
      check(started(run).find { |e| e['tag'] == 'second' }['pod'] == second, 'the second copy ran on the wrong pod')
      locks_gone
    end
  end

  # until_and_while_executing: the push lock is off once the job starts, so a
  # second push is accepted; the runtime lock the other pod holds then rejects it.
  def until_and_while_executing_across_pods
    [%w[gem native], %w[native gem]].each do |first, second|
      run = fresh
      # Scheduled a moment out, so the push lock is still up for the next check.
      check(push(second, InteropUntilAndWhileJob, [run, 'first'], queue: first, delay: 2), 'first push refused')
      check(push(first, InteropUntilAndWhileJob, [run, 'early'], queue: second).nil?,
            "#{first} pushed past #{second}'s push lock")
      wait("#{first} runs it") { started(run).any? }
      dup = push(second, InteropUntilAndWhileJob, [run, 'during'], queue: second)
      check(dup, 'push during execution refused (the push lock should be off)')
      wait("#{second} rejects the duplicate to the dead set") { Sidekiq::DeadSet.new.any? { |job| job.jid == dup } }
      check(started(run).size == 1, 'the duplicate ran beside the holder')
      Interop.release(run)
      wait('finished') { Interop.events(run, 'finish').size == 1 }
      locks_gone
    end
  end

  # A scheduled job keeps its lock through the wait, and the other pod's worker
  # runs it and frees it.
  def scheduled_job_keeps_its_lock
    [%w[gem native], %w[native gem]].each do |pusher, runner|
      run = fresh
      check(push(pusher, InteropUntilExecutedJob, [run, 'later'], queue: runner, delay: 2), 'scheduled push refused')
      check(push(runner, InteropUntilExecutedJob, [run, 'now'], queue: runner).nil?,
            "#{runner} pushed past a scheduled job's lock")
      wait("#{runner} runs the scheduled job") { Interop.events(run, 'finish').any? }
      check(Interop.events(run, 'finish').map { |e| e['tag'] } == ['later'], 'the wrong copy ran')
      locks_gone
    end
  end

  # A retry keeps the lock across its wait in the retry set, whichever pod pushes.
  def retry_keeps_its_lock
    [%w[gem native], %w[native gem]].each do |pusher, runner|
      run = fresh
      jid = push(pusher, InteropRetryJob, [run], queue: runner)
      wait('in the retry set') { Sidekiq::RetrySet.new.any? { |job| job.jid == jid } }
      check(push(pusher == 'gem' ? 'native' : 'gem', InteropRetryJob, [run, 'dup'], queue: runner).nil?,
            'a duplicate was accepted during the retry wait')
      wait('the retry succeeded') { Interop.events(run, 'finish').any? }
      check(Interop.events(run, 'attempt').size == 2, 'wrong number of attempts')
      locks_gone
    end
  end

  # A job that dies frees its lock (the death handler), whichever pod pushed it.
  def death_releases_the_lock
    [%w[gem native], %w[native gem]].each do |pusher, runner|
      run = fresh
      jid = push(pusher, InteropDyingJob, [run], queue: runner)
      wait("#{runner} kills it") { Sidekiq::DeadSet.new.any? { |job| job.jid == jid } }
      locks_gone
      check(push(pusher, InteropDyingJob, [run], queue: 'parked'), "#{pusher}: the dead job's lock survived")
      # The native API extension gives a cleared job's lock back, as the gem's does.
      Sidekiq::Queue.new('parked').clear
      locks_gone
    end
  end

  # The gem loaded and the native middleware in the same chains: the job is pushed
  # and run once, and only the gem locked it.
  def native_stands_down_beside_the_gem
    result = ask('gem', 'op' => 'stand_down')
    check(result['pushed'] && result['ran'] == 1, "pushed #{result['pushed']}, ran #{result['ran']} times")
    check(result['native_events'].empty?, "the native copy acted beside the gem: #{result['native_events']}")
    check(result['native_enabled'] == false, 'Wurk::UniqueJobs thinks it is SidekiqUniqueJobs in the gem pod')
    locks_gone
  end

  # --- helpers ------------------------------------------------------------

  def fresh = SecureRandom.hex(6)
  def started(run) = Interop.events(run, 'start')

  def locks_gone
    wait('every lock released') { lock_keys.empty? }
  rescue RuntimeError => e
    raise "#{e.message}; still in Redis: #{lock_keys.inspect}"
  end

  def lock_keys
    digests = Sidekiq.redis { |c| c.call('ZRANGE', 'uniquejobs:digests', 0, -1) }
    digests + Sidekiq.redis { |c| c.call('KEYS', 'uniquejobs:*:LOCKED') }
  end

  def check(condition, message)
    raise "interop failed: #{message}" unless condition
  end

  def wait(what, seconds: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      raise "interop timed out waiting for: #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  SCENARIOS = %i[
    same_digests push_locks_hold_across_pods runs_and_releases_across_pods while_executing_reschedules_across_pods
    until_and_while_executing_across_pods scheduled_job_keeps_its_lock retry_keeps_its_lock death_releases_the_lock
    native_stands_down_beside_the_gem
  ].freeze

  def run_all
    boot
    SCENARIOS.each do |scenario|
      # `parked` is a queue no worker reads: its jobs hold their locks.
      Sidekiq::Queue.new('parked').clear
      send(scenario)
      puts "  interop: #{scenario}"
    end
    puts 'sidekiq-unique-jobs interop (gem pod <-> native pod): passed'
  rescue StandardError
    dump_logs
    raise
  ensure
    shutdown
  end
end

InteropDriver.run_all if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
