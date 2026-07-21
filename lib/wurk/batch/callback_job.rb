# frozen_string_literal: true

require_relative '../worker'

module Wurk
  class Batch
    # Worker that runs a single batch callback. The target spec is one of:
    #
    #   "MyCallback"      → MyCallback.new.on_<event>(status, options)
    #   "MyCallback#done" → MyCallback.new.done(status, options)
    #   "#done"           → <batch callback_class>.new.done(status, options)
    #
    # The class-less form takes its class from the batch's `callback_class`
    # (spec §2.2), read from `b-<bid>` at run time — the spec travels through
    # the job payload as a plain String, so nothing here depends on anything
    # that a JSON round trip could lose.
    #
    # Failures inside the callback retry like any ordinary job — callbacks
    # MUST be idempotent.
    #
    # Spec: docs/target/sidekiq-pro.md §2.4.
    class CallbackJob
      include Wurk::Job

      # The spec names a class or a method that isn't there. Distinct from a
      # failure raised *by* the callback so the retry policy can tell the two
      # apart.
      class UnresolvableTarget < StandardError; end

      sidekiq_options retry: true

      # A missing constant or method does not heal with time, so the default 25
      # retries over ~21 days would only delay the news. Go straight to the dead
      # set on the first attempt: death handlers fire, the operator sees it now,
      # and the Dead tab's retry button is the recovery path once the callback
      # class is restored. Anything else the callback raises keeps normal retry.
      sidekiq_retry_in { |_count, exception| :kill if exception.is_a?(UnresolvableTarget) }

      def perform(bid, target_spec, event, options)
        klass, method = resolve(bid, target_spec.to_s, event)
        instance = klass.new
        unless instance.respond_to?(method)
          raise UnresolvableTarget, "batch #{bid}: #{klass}##{method} is not a public method"
        end

        instance.public_send(method, Wurk::Batch::Status.new(bid), options || {})
      end

      private

      def resolve(bid, spec, event)
        return [constantize(bid, spec), :"on_#{event}"] unless spec.include?('#')

        klass_name, method_name = spec.split('#', 2)
        klass_name = callback_class_for(bid) if klass_name.empty?
        [constantize(bid, klass_name), method_name.to_sym]
      end

      def constantize(bid, name)
        if name.nil? || name.empty?
          raise UnresolvableTarget, "batch #{bid}: callback spec names no class and the batch has no callback_class"
        end

        const = Object.const_get(name)
        raise UnresolvableTarget, "batch #{bid}: callback target #{name} is not a Class" unless const.is_a?(::Class)

        const
      rescue NameError
        raise UnresolvableTarget, "batch #{bid}: callback class #{name.inspect} is not defined"
      end

      def callback_class_for(bid)
        Wurk.redis { |conn| conn.call('HGET', "b-#{bid}", 'callback_class') }
      end
    end
  end
end
