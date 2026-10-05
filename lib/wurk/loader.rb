# frozen_string_literal: true

module Wurk
  # Deferred extension hooks, `Sidekiq.loader` (spec §30). An extension
  # registers `Sidekiq.loader.on_load(:api) { ... }` to patch a component once
  # it has loaded; registering after the component already loaded runs the
  # block at once. Wurk loads its whole API with `require "wurk"`, so `:api`
  # fires as soon as the alias layer is in place (end of compat.rb).
  class Loader
    def initialize
      @load_hooks = Hash.new { |h, k| h[k] = [] }
      @loaded = ::Set.new
      @lock = ::Mutex.new
    end

    # The block runs outside the lock so it may itself register hooks.
    def on_load(name, &block)
      run_now = @lock.synchronize do
        next true if @loaded.include?(name)

        @load_hooks[name] << block
        false
      end
      block.call if run_now
      nil
    end

    # Marks `name` loaded and runs its pending hooks once. A failing hook is
    # reported and the rest still run.
    def run_load_hooks(name)
      hooks = @lock.synchronize do
        @loaded << name
        @load_hooks.delete(name)
      end
      hooks&.each do |hook|
        hook.call
      rescue StandardError => e
        Wurk.configuration.handle_exception(e, { hook: name })
      end
      nil
    end
  end

  class << self
    attr_reader :loader
  end
  @loader = Loader.new
end
