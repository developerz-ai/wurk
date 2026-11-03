# frozen_string_literal: true

require_relative '../test_helper'
require 'rbconfig'
require 'tmpdir'

# A worker must not drop jobs because a test mode got switched on while it loaded.
# Real binaries, real Redis: the job only lands in the file if its enqueue went
# through Redis and a worker fetched it.
class WorkerTestModeGuardTest < Wurk::Test::UnitCase
  ROOT = File.expand_path('../..', __dir__)
  FIXTURE = File.join(ROOT, 'test/fixtures/test_mode_worker.rb')
  DEADLINE = 45

  %w[wurk wurkswarm].each do |binary|
    define_method("test_#{binary}_runs_a_job_enqueued_with_fake_mode_on_at_load") do
      Dir.mktmpdir do |dir|
        out = File.join(dir, 'ran')
        log = File.join(dir, 'log')
        pid = spawn_worker(binary, out, log)

        assert wait_for_file(out), "the job never ran:\n#{File.read(log)}"
        assert_includes File.read(log), 'silently drop every enqueue'
      ensure
        stop_worker(pid)
      end
    end
  end

  private

  def spawn_worker(binary, out, log)
    queue = "guard-#{Process.pid}-#{object_id}"
    env = { 'REDIS_URL' => Wurk::Test.redis_url, 'WURK_TEST_OUT' => out, 'WURK_TEST_QUEUE' => queue,
            'WURK_COUNT' => '1', 'COVERAGE' => nil, 'RAILS_ENV' => nil, 'RACK_ENV' => nil }
    Process.spawn(env, RbConfig.ruby, '-I', File.join(ROOT, 'lib'), File.join(ROOT, 'exe', binary),
                  '-r', FIXTURE, '-q', queue, '-c', '1', out: log, err: log, pgroup: true)
  end

  def wait_for_file(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEADLINE
    until File.exist?(path)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
    true
  end

  def stop_worker(pid)
    return unless pid

    Process.kill('TERM', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
