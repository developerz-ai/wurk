# frozen_string_literal: true

module Wurk
  # Load tiers (plan 101/06 L1-L4). `require "wurk"` loads the client tier only:
  # enqueue, the job DSL, the data API, and every middleware registered at load.
  # The rest is an `autoload` registered here and loaded on first reference: the
  # server tier (CLI, Swarm, Launcher and what they require), which a runner
  # reaches as it starts, and the on-demand tier (Web, Flow, Encryption, ...) most
  # processes never touch.
  #
  # Two server-side files stay in the client tier on purpose. processor.rb
  # registers an `at_exit` at load, and handlers run in reverse order of
  # registration, so loading it later would move its place in a host's exit
  # sequence. testing.rb is read by Client#raw_push on every push.
  #
  # `autoload`, never `const_missing`: `defined?(Wurk::Web)` is truthy before the
  # load, as gems that branch on it expect, and a reopen (`class
  # Sidekiq::Launcher`) loads the real class before it adds to it.
  #
  # A process that forks calls {Wurk.eager_load!} first (Swarm::Prefork): a
  # constant first touched in a child is a private copy in every child. Rails'
  # eager_load does not reach a plain `autoload`.
  module LazyLoader
    # Wurk::<name> => its file under lib/wurk. Registered before the client tier
    # loads, so a client-tier file may name any of these.
    TOP_LEVEL = {
      # Server tier.
      CLI: 'cli', Embedded: 'embedded', Swarm: 'swarm', Launcher: 'launcher', Manager: 'manager',
      Heartbeat: 'heartbeat', Scheduled: 'scheduled', Leader: 'leader',
      Cron: 'cron', Periodic: 'cron', History: 'history', Health: 'health', ShutdownGate: 'shutdown_gate',
      Topology: 'topology', RailsBoot: 'rails_boot',
      # On-demand tier.
      Web: 'web', Flow: 'flow', FlowSet: 'flow_set', ProfileSet: 'profile_set', ProfileRecord: 'profile_set',
      Deploy: 'deploy', Encryption: 'encryption', IterableJob: 'iterable_job', IterableJobQuery: 'iterable_job_query'
    }.freeze

    @registered = []

    class << self
      # `table` maps a constant name in `namespace` to a path relative to lib/wurk.
      def register(namespace, table)
        table.each do |name, path|
          namespace.autoload(name, ::File.expand_path(path, __dir__))
          @registered << [namespace, name]
        end
      end

      # Resolves every registered autoload, Sidekiq aliases included, so a fork
      # finds them all in shared pages. Idempotent.
      def eager_load!
        @registered.each { |namespace, name| namespace.const_get(name, false) }
        nil
      end

      def registered = @registered.dup
    end

    register(Wurk, TOP_LEVEL)
  end
end
