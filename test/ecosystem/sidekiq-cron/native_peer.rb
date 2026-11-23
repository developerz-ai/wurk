# frozen_string_literal: true

# The native half of interop.rb: wurk's own bundle, no sidekiq-cron gem, so
# `Sidekiq::Cron` is Wurk::SidekiqCron. Reads one JSON command per line on stdin
# and answers one JSON line on stdout, against the same Redis as the gem.

require 'json'
require 'sidekiq'
require 'tzinfo'

abort "native peer expected Wurk::SidekiqCron, got #{Sidekiq::Cron}" unless Sidekiq::Cron.equal?(Wurk::SidekiqCron)
abort 'native peer has the sidekiq-cron gem loaded' if Gem.loaded_specs.key?('sidekiq-cron')

Sidekiq.logger.level = Logger::WARN
Sidekiq::Cron.configure { |c| c.reschedule_grace_period = 300 }

# Never performed here; the gem side counts what lands in its queue.
class InteropTick
  include Sidekiq::Job
end

module NativePeer
  module_function

  def job(name) = Sidekiq::Cron::Job.find(name)

  def at(epoch) = Time.at(epoch).utc

  def run(command) # rubocop:disable Metrics/CyclomaticComplexity -- one branch per command
    args = command['args']
    case command['op']
    when 'ready' then true
    when 'load' then Sidekiq::Cron::Job.load_from_hash!(args.fetch('schedule'), source: 'schedule')
    when 'status' then job(args.fetch('name'))&.status
    when 'disable' then job(args.fetch('name')).disable!
    when 'enable' then job(args.fetch('name')).enable!
    when 'hash' then Sidekiq.redis { |c| c.call('HGETALL', Sidekiq::Cron::Job.redis_key(args.fetch('name'))) }
    when 'slots' then slots(args.fetch('cron'), args.fetch('times'))
    when 'fire' then !job(args.fetch('name')).test_and_enqueue_for_time!(at(args.fetch('at'))).nil?
    when 'poll' then Wurk::SidekiqCron::Poller.new(Sidekiq.default_configuration).enqueue(Time.now.utc) && true
    else raise ArgumentError, "unknown op #{command['op'].inspect}"
    end
  end

  def slots(cron, times)
    entry = Sidekiq::Cron::Job.new('name' => 'slots', 'cron' => cron, 'class' => 'InteropTick')
    times.map { |epoch| [entry.formatted_last_time(at(epoch)), entry.formatted_enqueue_time(at(epoch))] }
  end
end

$stdout.sync = true
$stdin.each_line do |line|
  puts JSON.generate(ok: NativePeer.run(JSON.parse(line)))
rescue StandardError => e
  puts JSON.generate(error: "#{e.class}: #{e.message}")
end
