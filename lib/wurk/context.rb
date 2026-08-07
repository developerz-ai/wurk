# frozen_string_literal: true

module Wurk
  # Thread-local logging context. Job state (jid, bid, tags, elapsed, …) is
  # attached here so loggers, middleware, and error handlers can pick it up
  # without threading the hash through every call. Storage lives in
  # `Thread.current[:wurk_context]` — never share across threads or forks.
  #
  # Spec: docs/target/sidekiq-free.md §29.
  module Context
    KEY = :wurk_context

    # Run `block` with `hash` merged onto the thread-local context. The prior
    # context is restored on exit, even if the block raises — safe to nest.
    def self.with(hash)
      prior = Thread.current[KEY]
      Thread.current[KEY] = prior ? prior.merge(hash) : hash
      yield
    ensure
      Thread.current[KEY] = prior
    end

    # Add a single key to the current thread's context. Creates the hash
    # if no enclosing `with` block has been opened yet.
    def self.add(key, value)
      Thread.current[KEY] ||= {}
      Thread.current[KEY][key] = value
    end

    # Read the current thread's context (or an empty hash if unset).
    def self.current
      Thread.current[KEY] || {}
    end
  end
end
