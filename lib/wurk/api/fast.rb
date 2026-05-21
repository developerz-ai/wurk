# frozen_string_literal: true

require_relative '../lua'
require_relative '../job_record'

module Wurk
  module API
    # Pro parity (§11): Lua-backed O(1)-round-trip replacements for the
    # ruby-side LRANGE / ZSCAN loops in Queue and SortedSet. Mixed into the
    # existing data API classes so the surface is `Sidekiq::Queue#delete_job(jid)`,
    # `Sidekiq::DeadSet#scan(pattern) { |JobRecord| … }` etc. — wire-compat
    # with Pro consumer code that drops in on a one-line require swap.
    #
    # We don't reimplement `Queue#size` (already LLEN, unchanged per spec).
    module Fast
      # Extension to Wurk::Queue. Pure server-side delete by jid / class — no
      # network round-trips per match. Returns the count of payloads removed.
      module QueueExt
        # @return [Integer] payloads removed (0 when jid absent; >0 only in
        #   the corner case of duplicate-jid corruption).
        def delete_job(jid)
          raise ArgumentError, 'jid required' if jid.nil? || jid.to_s.empty?

          Wurk.redis do |conn|
            Wurk::Lua::Loader.eval_cached(
              conn,
              :fast_delete_job,
              keys: [Keys.queue(name)],
              argv: [jid.to_s]
            )
          end.to_i
        end

        # @param klass [Class, String, Symbol]
        # @return [Integer] payloads removed.
        def delete_by_class(klass)
          klass_name = klass.is_a?(Class) ? klass.name : klass.to_s
          raise ArgumentError, 'class name required' if klass_name.empty?

          Wurk.redis do |conn|
            Wurk::Lua::Loader.eval_cached(
              conn,
              :fast_delete_by_class,
              keys: [Keys.queue(name)],
              argv: [klass_name]
            )
          end.to_i
        end
      end

      # Extension to Wurk::SortedSet / JobSet. The base `scan(match, count)`
      # already yields `(value, score)` pairs via ZSCAN — Pro promotes the
      # surface to yield `JobRecord` directly so callers can `entry.delete`
      # / `entry.retry` without re-parsing JSON.
      #
      # The new behavior is enabled by *block arity*: a 1-arg block (or
      # block.lambda? + a 1-param signature) receives `JobRecord`; legacy
      # 2-arg blocks (`|value, score|`) keep the raw shape. This preserves
      # the existing two-arg contract used by JobSet#find_job internally.
      module SortedSetExt
        def scan(match, count = 100, &block)
          return enum_for(:scan, match, count) unless block

          if block.arity == 1
            super do |value, score|
              block.call(Wurk::SortedEntry.new(self, score, value))
            end
          else
            super
          end
        end
      end
    end
  end
end

Wurk::Queue.include(Wurk::API::Fast::QueueExt)
Wurk::SortedSet.prepend(Wurk::API::Fast::SortedSetExt)
