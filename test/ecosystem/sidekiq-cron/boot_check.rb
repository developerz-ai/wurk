# frozen_string_literal: true

# sidekiq-cron's own suite never boots a Launcher, so it stayed green while Wurk
# discarded the gem's poller and no cron job ever fired. This starts the real
# executables with the gem loaded and asserts a job is enqueued and run from a
# schedule: `sidekiq` through the shim gem, and `wurkswarm`, whose forked children
# inherit a frozen configuration the gem's Launcher prepend then writes to.
#
# Run under the harness bundle: BUNDLE_GEMFILE=test/ecosystem/sidekiq-cron/Gemfile
#   ECOSYSTEM_CHECKOUT=<checkout> REDIS_URL=<db the check may flush> bundle exec ruby boot_check.rb

require 'fileutils'
require 'json'
require 'logger'
require 'sidekiq'
require 'sidekiq-cron'
require 'tmpdir'

OUT = ENV.fetch('BOOT_CHECK_OUT') { File.join(Dir.tmpdir, "wurk-cron-boot-check-#{Process.pid}.jsonl") }
ENV['BOOT_CHECK_OUT'] = OUT
TICKS_WANTED = 2
DEADLINE_SECONDS = 45

class BootCheckTick
  include Sidekiq::Job

  def perform
    File.open(OUT, 'a') { |f| f.puts(JSON.generate(at: Time.now.to_f)) }
  end
end

Sidekiq::Cron.configure { |c| c.cron_poll_interval = 1 }

Sidekiq.configure_server do |config|
  config.on(:startup) do
    Sidekiq::Cron::Job.load_from_hash!(
      { 'boot_check' => { 'cron' => '* * * * * *', 'class' => 'BootCheckTick', 'active_job' => false } },
      source: 'schedule'
    )
  end
end

def ticks_under(*command)
  FileUtils.rm_f(OUT)
  Sidekiq.redis { |c| c.call('FLUSHDB') }
  log = "#{OUT}.log"
  server = Process.spawn('bundle', 'exec', *command, '-r', File.expand_path(__FILE__), '-c', '2',
                         out: log, err: log, pgroup: true)
  ticks = 0
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEADLINE_SECONDS
  while ticks < TICKS_WANTED && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    sleep 0.25
    ticks = File.exist?(OUT) ? File.readlines(OUT).size : 0
  end
  Process.kill('TERM', server)
  Process.wait(server)
  return true if ticks >= TICKS_WANTED

  warn "cron boot check (#{command.join(' ')}): #{ticks} of #{TICKS_WANTED} ticks in #{DEADLINE_SECONDS}s"
  warn File.read(log).lines.last(20).join
  false
ensure
  FileUtils.rm_f([OUT, log])
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  ENV['WURK_COUNT'] = '1'
  results = [%w[sidekiq], %w[wurkswarm]].map { |command| ticks_under(*command) }
  exit 1 unless results.all?

  puts "cron boot check: #{TICKS_WANTED} ticks under sidekiq and wurkswarm"
end
