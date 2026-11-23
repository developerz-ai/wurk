# frozen_string_literal: true

module Wurk
  module SidekiqCron
    # A cron entry's `args`, stored and replayed exactly as sidekiq-cron does:
    # JSON in the `args` field, a bare Hash wrapped as one argument, a
    # GlobalID-capable record stored as `{"_sc_globalid" => gid}` and located
    # again at enqueue time. GlobalID is used only when the host loaded it.
    module Arguments
      GLOBALID_KEY = '_sc_globalid'

      module_function

      def parse(args, symbolize)
        case args
        when ::String then parse_string(args, symbolize)
        when ::Hash then symbolize ? [symbolize_keys(serialize(args))] : [serialize(args)]
        when ::Array then symbolize ? symbolize_each(serialize(args)) : serialize(args)
        else global_id?(args) ? [global_id_hash(args)] : [*args]
        end
      end

      def parse_string(args, symbolize)
        parsed = ::JSON.parse(args)
        symbolize ? symbolize_each(parsed) : parsed
      rescue ::JSON::ParserError
        [*args]
      end

      def serialize(argument)
        case argument
        when ::Array then argument.map { |arg| serialize(arg) }
        when ::Hash then argument.to_h { |key, value| [key, serialize(value)] }
        else global_id?(argument) ? global_id_hash(argument) : argument
        end
      end

      def deserialize(argument)
        case argument
        when ::Array then argument.map { |arg| deserialize(arg) }
        when ::Hash
          return ::GlobalID::Locator.locate(argument[GLOBALID_KEY]) if argument.size == 1 && argument.key?(GLOBALID_KEY)

          argument.transform_values { |value| deserialize(value) }
        else argument
        end
      end

      def symbolize_each(input)
        return symbolize_keys(input) if input.is_a?(::Hash)
        return input unless input.is_a?(::Array)

        input.map { |arg| arg.is_a?(::Hash) ? symbolize_keys(arg) : arg }
      end

      def symbolize_keys(hash) = hash.transform_keys(&:to_sym)

      def global_id?(value)
        defined?(::GlobalID::Identification) && value.is_a?(::GlobalID::Identification)
      end

      def global_id_hash(record)
        { GLOBALID_KEY => record.to_global_id.to_s }
      rescue ::URI::GID::MissingModelIdError
        raise ArgumentError, "Unable to serialize #{record.class} without an id. (Maybe you forgot to call save?)"
      end
    end
  end
end
