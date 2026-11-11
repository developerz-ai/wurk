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
    # The autoload targets this process registered, by the exact path the VM
    # hands to `require` when the constant is first referenced.
    @features = {}
    @locks = {}
    @locks_guard = Mutex.new
    @guard_installed = false

    # A plain Mutex is not reentrant, and a lazy feature's file loads another
    # lazy feature on the same thread: the Sidekiq aliases reach the server
    # tier through one file (compat/server.rb names CLI, Launcher, Manager and
    # the rest). The owning thread walks back in; the next waiter gets the lock
    # when the owner leaves.
    class LoadLock
      def initialize
        @mutex = Mutex.new
        @owner = nil
      end

      def synchronize
        return yield if @owner == Thread.current

        @mutex.synchronize do
          @owner = Thread.current
          begin
            yield
          ensure
            @owner = nil
          end
        end
      end
    end

    class << self
      # `table` maps a constant name in `namespace` to a path relative to lib/wurk.
      def register(namespace, table)
        table.each do |name, path|
          feature = ::File.expand_path(path, __dir__)
          namespace.autoload(name, feature)
          @registered << [namespace, name]
          @features[feature] = true
        end
        install_load_guard!
      end

      # Resolves every registered autoload, Sidekiq aliases included, so a fork
      # finds them all in shared pages. Idempotent.
      def eager_load!
        @registered.each { |namespace, name| namespace.const_get(name, false) }
        nil
      end

      def registered = @registered.dup

      # Ruby's `autoload` is not thread-safe on every Ruby Wurk supports: two
      # threads that first-reference two constants backed by the same file can
      # each end up reading that file and waiting for the other, and the
      # process dies with "No live threads left. Deadlock?"
      # (bugs.ruby-lang.org/issues/18782 and #21719). The VM asks the main
      # object to `require` an autoload's target, so that call is the one place
      # Wurk can take a lock before the file is read.
      #
      # The lock is per feature, not global: a feature's file loads other
      # features (compat/server.rb names the server tier), and a global lock
      # would hold across that nesting while Ruby's own per-feature lock waits
      # the other way — a cycle of its own. Per feature, the wait is always for
      # the same file, and the feature graph has no cycles, so the only way out
      # is forward.
      def install_load_guard!
        return if @guard_installed

        @guard_installed = true
        main = TOPLEVEL_BINDING.receiver
        # Prepended, not a singleton method: `super` keeps the original
        # `require` in the lookup chain. A captured `Method` object resolved a
        # feature differently and broke Zeitwerk's namespace autoloads (the
        # dummy app's `app/jobs/demo` directory).
        main.singleton_class.prepend(Module.new do
          define_method(:require) do |feature|
            Wurk::LazyLoader.load(feature) { super(feature) }
          end
        end)
      end

      # Reads a lazy feature under its own lock. Every other require goes
      # straight through.
      def load(feature, &block)
        return block.call unless @features.key?(feature)

        lock_for(feature).synchronize(&block)
      end

      private

      def lock_for(feature)
        @locks_guard.synchronize { @locks[feature] ||= LoadLock.new }
      end
    end

    register(Wurk, TOP_LEVEL)
  end
end
