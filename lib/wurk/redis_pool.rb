# frozen_string_literal: true

module Wurk
  # Per-process pool over redis-client. Never share a socket across forks:
  # the parent closes the pool before fork, each child opens a fresh one.
  # See docs/idea/03-process-model.md (boot ordering step 3 & 5).
  class RedisPool
    def initialize(**opts); end

    def with(&block); end

    def disconnect!; end
  end
end
