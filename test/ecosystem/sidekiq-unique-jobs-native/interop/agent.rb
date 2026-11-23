# frozen_string_literal: true

# One pod's client, driven by interop.rb: a JSON command per stdin line, a reply
# per stdout line marked `REPLY ` (the loggers write to stdout too). The same file
# runs in the gem pod and the native pod.

$stdout.sync = true
require_relative 'jobs'

# Payload shapes whose prepared lock fields both implementations must agree on.
module InteropDigests
  class ProcArgsJob
    include Sidekiq::Job

    sidekiq_options lock: :until_executed, lock_args_method: ->(args) { [args[0], args.dig(1, 'id')] }
  end

  class SymbolArgsJob
    include Sidekiq::Job

    sidekiq_options lock: :until_executed, lock_args_method: :lock_args
    def self.lock_args(args) = args.first(2)
  end

  class ImplicitArgsMethodJob
    include Sidekiq::Job

    sidekiq_options lock: :while_executing
    def self.lock_args(args) = [args.last]
  end

  class AllArgsJob
    include Sidekiq::Job

    sidekiq_options lock: :until_and_while_executing, lock_ttl: 60, lock_timeout: 3
  end

  class AcrossQueuesJob
    include Sidekiq::Job

    sidekiq_options lock: :until_executed, unique_across_queues: true, lock_ttl: ->(args) { args[0].to_i * 10 }
  end

  class AcrossWorkersJob
    include Sidekiq::Job

    sidekiq_options lock: :until_expired, unique_across_workers: true, lock_ttl: 120
  end

  class PrefixJob
    include Sidekiq::Job

    sidekiq_options lock: :until_executing, lock_prefix: 'treasury', lock_args_method: ->(_args) { [] }
  end

  class StringMethodJob
    include Sidekiq::Job

    # A String method name is ignored by the gem (only Proc and Symbol filter).
    sidekiq_options lock: :until_executed, lock_args_method: 'lock_args'
  end
end

# Everything a lock reads, as `Job.prepare` leaves it.
FIELDS = %w[lock lock_args lock_digest lock_prefix lock_ttl lock_timeout].freeze

def prepared(item)
  out = SidekiqUniqueJobs::Job.prepare(item)
  FIELDS.to_h { |field| [field, out[field].is_a?(Symbol) ? out[field].to_s : out[field]] }
end

def push(cmd)
  klass = Object.const_get(cmd.fetch('class'))
  setter = klass.set(queue: cmd.fetch('queue'))
  cmd['in'] ? setter.perform_in(cmd['in'], *cmd.fetch('args')) : setter.perform_async(*cmd.fetch('args'))
end

# With the gem loaded, the native middleware has to pass every job through: in
# chains holding both, the job is pushed and run once, and the native copy never
# locks or unlocks anything (its reflections count what it did).
def stand_down
  raise 'stand_down runs in the gem pod' if Interop.native?

  native_events = []
  Wurk::UniqueJobs.reflect do |on|
    on.locked { native_events << :locked }
    on.unlocked { native_events << :unlocked }
  end
  client = Sidekiq::Middleware::Chain.new
  client.add SidekiqUniqueJobs::Middleware::Client
  client.add Wurk::UniqueJobs::Middleware::Client
  server = Sidekiq::Middleware::Chain.new
  server.add SidekiqUniqueJobs::Middleware::Server
  server.add Wurk::UniqueJobs::Middleware::Server

  item = { 'class' => 'InteropUntilExecutedJob', 'queue' => 'parked', 'jid' => SecureRandom.hex(12),
           'args' => ["standdown#{SecureRandom.hex(4)}", 'x'] }
  pushed = client.invoke('InteropUntilExecutedJob', item, 'parked', nil) { item }
  ran = 0
  server.invoke(InteropUntilExecutedJob.new, Sidekiq.load_json(Sidekiq.dump_json(pushed)), 'parked') { ran += 1 }
  { 'pushed' => !pushed.nil?, 'ran' => ran, 'native_events' => native_events.map(&:to_s),
    'native_enabled' => Wurk::UniqueJobs.native? }
end

$stdin.each_line do |line|
  cmd = JSON.parse(line)
  result = case cmd.fetch('op')
           when 'push' then push(cmd)
           when 'prepare' then prepared(cmd.fetch('item'))
           when 'stand_down' then stand_down
           when 'implementation' then SidekiqUniqueJobs.name
           else raise "unknown op #{cmd['op']}"
           end
  puts "REPLY #{JSON.generate('ok' => result)}"
rescue StandardError => e
  puts "REPLY #{JSON.generate('error' => "#{e.class}: #{e.message}")}"
end
