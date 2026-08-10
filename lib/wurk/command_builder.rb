# frozen_string_literal: true

require 'redis-client'

module Wurk
  # Fast path for redis-client's command normalization.
  #
  # `RedisClient::CommandBuilder.generate` splices Hash arguments with a
  # `flat_map` and then stringifies Symbols/Integers/Floats with a `map!` —
  # two array allocations and two per-element type dispatches for a command
  # whose arguments are already Strings. Every command Wurk sends per job is
  # exactly that shape (LMOVE, LREM, DEL, LPUSH, SADD), and the fetch pipeline
  # sends three of them. Measured ~4x faster on those commands (2.2µs → 0.6µs
  # each) with `bench/command_builder.rb`.
  #
  # Anything else — a Hash to splice, a Symbol or a number to stringify,
  # keyword arguments, an empty command — falls straight through to
  # redis-client's own builder. This is a shortcut, never a second
  # implementation of the semantics, so a host app calling
  # `Sidekiq.redis { |c| c.call("HSET", key, hash) }` is unaffected.
  #
  # The array is duped rather than handed back: `call_v` and the pipelined
  # forms pass the caller's own array through, and redis-client's builder
  # always returns a fresh one that middleware is free to mutate in place.
  module CommandBuilder
    module_function

    def generate(args, kwargs = nil)
      return args.dup if fast?(args, kwargs)

      ::RedisClient::CommandBuilder.generate(args, kwargs)
    end

    # Split out, and public, because the two branches produce byte-identical
    # output by construction — which leaves allocation count as the only
    # runtime difference between "the shortcut fired" and "it silently didn't",
    # and that is not something a test can assert safely in a process running
    # other suites. So the decision itself is what the suite asserts.
    #
    # `kwargs` is nil only from `call_v` and the scan helpers. Every `call`,
    # `blocking_call` and pipelined `call` arrives with `**kwargs` already
    # splatted into a Hash — EMPTY when the caller passed no keywords — so a
    # guard that only tested `.nil?` sent the entire hot path down the slow
    # branch while every direct-call test still passed.
    def fast?(args, kwargs)
      (kwargs.nil? || kwargs.empty?) && !args.empty? && args.all?(String)
    end
  end
end
