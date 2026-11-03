# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'redis_guard'

# A gem's own suite rarely boots a real worker, so it can stay green while the gem
# does nothing in production. Each harness's boot_check.rb loads its gem into the
# real executables, every way a worker can come up, and watches for the work.
module BootCheck
  DEADLINE_SECONDS = 45

  # `wurkswarm` is the one that runs Bundler.require of the default group before
  # forking, and its children inherit a frozen configuration. The last mode is what
  # rspec-sidekiq does outside a Gemfile's test group.
  MODES = {
    'sidekiq' => [%w[sidekiq], {}],
    'wurkswarm, preload on' => [%w[wurkswarm], {}],
    'wurkswarm, preload off' => [%w[wurkswarm], { 'WURK_PRELOAD' => '' }],
    'wurkswarm, fake testing mode at load' => [%w[wurkswarm], { 'BOOT_CHECK_FAKE_MODE' => '1' }]
  }.freeze

  OUT = ENV.fetch('BOOT_CHECK_OUT') { File.join(Dir.tmpdir, "wurk-boot-check-#{Process.pid}.jsonl") }
  ENV['BOOT_CHECK_OUT'] = OUT

  module_function

  def record(row) = File.open(OUT, 'a') { |f| f.puts(JSON.generate(row)) }
  def rows = File.exist?(OUT) ? File.readlines(OUT).map { |line| JSON.parse(line) } : []

  # Called from the top of a boot_check.rb, in the worker it starts as well as in
  # the driver: `Sidekiq.testing!` is the part that belongs to the worker.
  def load_into_worker
    Sidekiq.testing!(:fake) if ENV['BOOT_CHECK_FAKE_MODE']
  end

  # Runs the driver only when `script` is the program, so -r'ing it is safe. The
  # block runs once per mode with the worker up, and is done when it returns true.
  def drive(script, gem_name, &block)
    return unless File.expand_path($PROGRAM_NAME) == File.expand_path(script)

    results = MODES.map { |label, (command, env)| run_mode(script, gem_name, label, command, env, &block) }
    exit 1 unless results.all?

    puts "#{gem_name} boot check: passed under #{MODES.keys.join('; ')}"
  end

  def run_mode(script, gem_name, label, command, env, &)
    FileUtils.rm_f(OUT)
    flush_harness_db
    log = "#{OUT}.log"
    worker_env = { 'WURK_COUNT' => '1', 'RAILS_ENV' => nil, 'RACK_ENV' => nil }.merge(env)
    server = Process.spawn(worker_env, 'bundle', 'exec', *command,
                           '-r', File.expand_path(script), '-c', '2', out: log, err: log, pgroup: true)
    return true if wait_until(&)

    warn "#{gem_name} boot check (#{label}): nothing happened in #{DEADLINE_SECONDS}s"
    warn File.read(log).lines.last(20).join
    false
  ensure
    stop(server)
    FileUtils.rm_f([OUT, log])
  end

  def flush_harness_db
    Sidekiq.redis do |conn|
      EcosystemRedisGuard.check_connection!(conn.call('CLIENT', 'INFO'))
      conn.call('FLUSHDB')
    end
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEADLINE_SECONDS
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.25
    end
    true
  end

  def stop(pid)
    return unless pid

    Process.kill('TERM', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
