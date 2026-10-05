# frozen_string_literal: true

require_relative '../lua'

module Wurk
  module API
    # Pro parity (§11): Lua-backed O(1)-round-trip replacements for the
    # ruby-side LRANGE loops in Queue. Mixed into the existing data API class
    # so the surface is `Sidekiq::Queue#delete_job(jid)` — wire-compat with Pro
    # consumer code that drops in on a one-line require swap.
    #
    # We don't reimplement `Queue#size` (already LLEN, unchanged per spec).
    module Fast
      # Extension to Wurk::Queue. Pure server-side delete by jid / class — no
      # network round-trips per match.
      module QueueExt
        # @return [String, nil] the deleted job's JSON, or nil when no job in
        #   the queue has that jid — Pro's contract, so `if q.delete_job(jid)`
        #   branches on whether anything was removed.
        def delete_job(jid)
          raise ArgumentError, 'jid required' if jid.nil? || jid.to_s.empty?

          Wurk.redis do |conn|
            Wurk::Lua::Loader.eval_cached(
              conn,
              :fast_delete_job,
              keys: [Keys.queue(name)],
              argv: [jid.to_s]
            )
          end
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
    end
  end
end

Wurk::Queue.include(Wurk::API::Fast::QueueExt)
