# frozen_string_literal: true

module Wurk
  class Swarm
    # The parent's last memory step before its first fork, shared by every
    # swarm entry point (`wurkswarm` and the railtie's co-hosted swarm): load
    # what each child would otherwise load for itself (Wurk's autoloads
    # included: Wurk.eager_load!), then settle the heap, so
    # the children start on pages they share copy-on-write instead of N private
    # copies. Opens no socket, so it may sit between steps 3 and 4. Its effect
    # is the t=0 shared ratio in bench/rss_soak.rb (`RSS_JOBS=0`).
    module Prefork
      # Features a child requires after the fork. `fiddle` arms PR_SET_PDEATHSIG
      # (OrphanGuard#arm_pdeathsig) in every Linux child.
      CHILD_FEATURES = %w[fiddle].freeze

      module_function

      # Once, before the first fork only: a respawn forks from a parent that may
      # be a live web process, where a full compaction is a pause its requests
      # would feel. RUBY_DISABLE_WARMUP=1 skips it, as it does `Process.warmup`.
      def run(env = ENV, periodic: nil)
        Wurk.eager_load!
        require_child_features
        Wurk::Cron.prefork(periodic) if periodic
        warmup unless env['RUBY_DISABLE_WARMUP'] == '1'
      end

      def require_child_features
        CHILD_FEATURES.each { |feature| try_require(feature) }
        # Only a host that loaded Vernier can profile a job (Profiler).
        try_require('tempfile') if defined?(::Vernier)
      end

      # `Process.warmup` (Ruby >= 3.3) is a full GC, compaction, promotion of
      # survivors to the old generation and a malloc_trim. The 3.2 floor gets
      # the part it has: full GC, then compaction where the platform supports it.
      def warmup(process = ::Process, collector = ::GC)
        return process.warmup if process.respond_to?(:warmup)

        collector.start(full_mark: true, immediate_sweep: true)
        collector.compact if collector.respond_to?(:compact)
      rescue ::NotImplementedError
        nil
      end

      def try_require(feature)
        require feature
      rescue ::LoadError
        nil
      end
    end
  end
end
