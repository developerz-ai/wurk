# frozen_string_literal: true

# The real sidekiq-cron gem (this harness's bundle) and wurk's native
# Sidekiq::Cron (native_peer.rb, in wurk's own bundle, with no gem) against one
# Redis. A fleet mid-rollout runs both, so each has to read the other's entries,
# honour the other's enable/disable, and never fire an occurrence the other
# already fired. Also: with the gem bundled, wurk's native code never loads.
#
# Run under the harness bundle: BUNDLE_GEMFILE=test/ecosystem/sidekiq-cron/Gemfile
#   ECOSYSTEM_CHECKOUT=<checkout> REDIS_URL=<private server>/15 bundle exec ruby interop.rb

require 'json'
require 'open3'
require 'sidekiq'
require 'sidekiq-cron'
require 'sidekiq/cron/web'
require_relative '../boot_check_support'

module Interop
  WURK_ROOT = File.expand_path('../../..', __dir__)
  QUEUE = 'interop'
  # Every distinct schedule shape one adopter's production file uses, plus names,
  # aliases and a zone with DST.
  CRONS = [
    '*/5 * * * * America/Caracas', '0 6 * * * America/Caracas', '5-55/10 * * * * America/Caracas',
    '0 9 * * 1-5 America/Caracas', '0 0,6,12,18 * * * America/Caracas', '37 */4 * * * America/Caracas',
    '15,45 * * * * America/Caracas', '0 3 * * 0 America/Caracas', '0 3 * * * America/Bogota',
    '5 * * * * America/New_York', '30 1 * * * America/New_York', '0 8 * * mon-fri', '0 0 1 jan,jul *',
    '@daily', '@hourly America/Caracas', '0 3 1 * *', '* * * * *', '30 2 * * * America/New_York'
  ].freeze
  # Around both 2026 US clock changes (America/New_York), and ordinary offsets.
  TIMES = [Time.utc(2026, 3, 8, 6), Time.utc(2026, 11, 1, 4)].flat_map do |base|
    [0, 0.5, 1, 59, 61, 3599, 3600.7, 5400, 7200, 9000, 26 * 3600, 40 * 86_400].map { |offset| base.to_i + offset }
  end.freeze

  class Failure < StandardError; end

  module_function

  def check(label, expected, actual)
    raise Failure, "#{label}: expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual

    puts "  ok  #{label}"
  end

  def peer
    @peer ||= begin
      env = { 'BUNDLE_GEMFILE' => File.join(WURK_ROOT, 'Gemfile'), 'REDIS_URL' => ENV.fetch('REDIS_URL'),
              'BUNDLE_IGNORE_CONFIG' => nil, 'BUNDLE_PATH' => nil, 'RUBYOPT' => nil }
      script = File.join(__dir__, 'native_peer.rb')
      Bundler.with_unbundled_env { Open3.popen2(env, 'bundle', 'exec', 'ruby', script, chdir: WURK_ROOT) }
    end
  end

  def native(command, **args)
    stdin, stdout, = peer
    stdin.puts(JSON.generate(op: command, args: args))
    reply = JSON.parse(stdout.gets || raise(Failure, "native peer exited during #{command}"))
    raise Failure, "native #{command}: #{reply['error']}" if reply.key?('error')

    reply['ok']
  end

  def gem_job(name) = Sidekiq::Cron::Job.find(name)
  def gem_fired?(name, at) = !gem_job(name).test_and_enqueue_for_time!(Time.at(at).utc).nil?
  def queued = Sidekiq.redis { |c| c.call('LLEN', "queue:#{QUEUE}") }

  def entry(cron = '*/5 * * * * America/Caracas', **extra)
    { 'cron' => cron, 'class' => 'InteropTick', 'queue' => QUEUE, 'active_job' => false,
      'description' => 'interop', 'args' => [10] }.merge(extra.transform_keys(&:to_s))
  end

  # The load path finds the gem's copies first here, so wurk's same-named entry
  # files are loaded by path too: each must hand off to the gem.
  def stands_down
    %w[sidekiq-cron.rb sidekiq/cron.rb sidekiq/cron/web.rb].each { |file| require File.join(WURK_ROOT, 'lib', file) }
    check('Sidekiq::Cron::Job is the gem', true,
          Sidekiq::Cron::Job.instance_method(:save).source_location.first.start_with?(ENV.fetch('ECOSYSTEM_CHECKOUT')))
    check('wurk native sidekiq-cron not loaded', nil, defined?(Wurk::SidekiqCron))
    check('wurk registered no autoload for Sidekiq::Cron', nil, Sidekiq.autoload?(:Cron))
    launcher = Sidekiq::Launcher.new(Sidekiq.default_configuration)
    check('wurk launcher builds no native cron poller', nil, launcher.sidekiq_cron_poller)
  end

  def keyspace
    Sidekiq::Cron::Job.load_from_hash!({ 'from_gem' => entry }, source: 'schedule')
    native(:load, schedule: { 'from_gem' => entry, 'from_native' => entry })
    gem_side = Sidekiq.redis { |c| c.call('HGETALL', Sidekiq::Cron::Job.redis_key('from_gem')) }
    native_side = native(:hash, name: 'from_native')
    check('native writes the gem hash fields', gem_side.keys.sort, native_side.keys.sort)
    check('native writes the gem hash values', gem_side.except('name', 'last_enqueue_time'),
          native_side.except('name', 'last_enqueue_time'))
    check('the gem reads a native entry', [true, 'enabled', QUEUE, [10]],
          gem_job('from_native').then { |j| [j.valid?, j.status, j.queue_name_with_prefix, j.args] })
  end

  def status
    gem_job('from_gem').disable!
    check('disabled by the gem, disabled for native', 'disabled', native(:status, name: 'from_gem'))
    native(:enable, name: 'from_gem')
    check('enabled by native, enabled for the gem', 'enabled', gem_job('from_gem').status)
    native(:disable, name: 'from_native')
    Sidekiq::Cron::Job.load_from_hash!({ 'from_gem' => entry, 'from_native' => entry('0 6 * * * America/Caracas') },
                                       source: 'schedule')
    check('disabled by native, still disabled after the gem reloads an edited schedule', 'disabled',
          gem_job('from_native').status)
    native(:load, schedule: { 'from_gem' => entry, 'from_native' => entry('0 7 * * * America/Caracas') })
    check('and after native reloads it', 'disabled', gem_job('from_native').status)
  end

  def slots
    CRONS.each do |cron|
      gem_entry = Sidekiq::Cron::Job.new('name' => 'slots', 'cron' => cron, 'class' => 'InteropTick')
      expected = TIMES.map do |t|
        at = Time.at(t).utc
        [gem_entry.formatted_last_time(at), gem_entry.formatted_enqueue_time(at)]
      end
      check("same occurrence as fugit for #{cron.inspect}", expected, native(:slots, cron: cron, times: TIMES))
    end
  end

  # Both sides offered the same occurrences; the queue gets one push each.
  def fires_once
    Sidekiq::Cron::Job.destroy_all!
    Sidekiq.redis { |c| c.call('DEL', "queue:#{QUEUE}") }
    Sidekiq::Cron::Job.load_from_hash!({ 'every_minute' => entry('* * * * *') }, source: 'schedule')
    start = (Time.now.to_i / 60 * 60) + 3600
    pushes = (1..6).sum do |minute|
      at = start + (minute * 60) + 2
      native_first = minute.odd?
      first = native_first ? native(:fire, name: 'every_minute', at: at) : gem_fired?('every_minute', at)
      second = native_first ? gem_fired?('every_minute', at) : native(:fire, name: 'every_minute', at: at)
      check("minute #{minute}: the side asked first fires, the other does not", [true, false], [first, second])
      1
    end
    check('six occurrences, six jobs', pushes, queued)
  end

  # Real pollers, real clock: both poll right after a minute boundary.
  def pollers_fire_once
    Sidekiq::Cron::Job.destroy_all!
    Sidekiq.redis { |c| c.call('DEL', "queue:#{QUEUE}") }
    sleep(1) until Time.now.sec.between?(5, 50)
    Sidekiq::Cron::Job.load_from_hash!({ 'every_minute' => entry('* * * * *') }, source: 'schedule')
    sleep(0.2) until Time.now.sec.between?(2, 4)
    gem_poller = Sidekiq::Cron::Poller.new(Sidekiq.default_configuration)
    6.times do
      native(:poll)
      gem_poller.enqueue
    end
    check('one minute, both pollers, one job', 1, queued)
  end

  def run
    puts 'sidekiq-cron interop (gem vs native, one Redis):'
    stands_down
    BootCheck.flush_harness_db
    native(:ready)
    %i[keyspace status slots fires_once pollers_fire_once].each { |step| send(step) }
    puts 'sidekiq-cron interop: passed'
  rescue Failure => e
    warn "sidekiq-cron interop FAILED: #{e.message}"
    exit 1
  ensure
    peer.first.close if @peer
  end
end

Sidekiq.logger.level = Logger::WARN
Sidekiq::Cron.configure { |c| c.reschedule_grace_period = 300 }

class InteropTick
  include Sidekiq::Job
end

Interop.run
