# frozen_string_literal: true

require_relative '../worker'

module Wurk
  class Batch
    # Worker that runs a single batch callback. Target may be a Class name
    # ("MyCallback" → `MyCallback.new.on_<event>(status, options)`) or a
    # "Klass#method" spec ("Foo#bar" → `Foo.new.bar(status, options)`).
    # Failures retry like any ordinary job — callbacks MUST be idempotent.
    #
    # Spec: docs/target/sidekiq-pro.md §2.4.
    class CallbackJob
      include Wurk::Job

      sidekiq_options retry: true

      def perform(bid, target_spec, event, options)
        klass, method = resolve(target_spec, event)
        instance = klass.new
        status   = Wurk::Batch::Status.new(bid)
        instance.public_send(method, status, options || {})
      end

      private

      def resolve(spec, event)
        if spec.include?('#')
          klass_name, method_name = spec.split('#', 2)
          [Object.const_get(klass_name), method_name.to_sym]
        else
          [Object.const_get(spec), :"on_#{event}"]
        end
      end
    end
  end
end
