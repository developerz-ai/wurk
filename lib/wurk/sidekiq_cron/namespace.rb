# frozen_string_literal: true

module Wurk
  module SidekiqCron
    # `Sidekiq::Cron::Namespace`: which `cron_jobs:<namespace>` sets exist.
    # `available_namespaces` is the explicit list, `:auto` reads Redis, nil
    # means only the default.
    class Namespace
      class << self
        def all
          configured = SidekiqCron.configuration.available_namespaces
          names = case configured
                  when nil then []
                  when ::Array then configured
                  when :auto then discovered
                  else raise ArgumentError, "Unexpected value for `available_namespaces`: #{configured.inspect}"
                  end
          names | [SidekiqCron.configuration.default_namespace]
        end

        def all_with_count
          all.map { |name| { count: count(name), name: name } }
        end

        def count(name = SidekiqCron.configuration.default_namespace)
          ::Sidekiq.redis { |conn| conn.scard("#{Job::JOBS_PREFIX}#{name}") }
        end

        def available_namespaces_provided?
          configured = SidekiqCron.configuration.available_namespaces
          !configured.nil? && configured != :auto
        end

        private

        # SCAN, not the gem's KEYS: the same answer without blocking the server.
        def discovered
          found = []
          cursor = '0'
          ::Sidekiq.redis do |conn|
            loop do
              cursor, keys = conn.call('SCAN', cursor, 'MATCH', "#{Job::JOBS_PREFIX}*", 'COUNT', 1000)
              found.concat(keys)
              break if cursor == '0'
            end
          end
          found.uniq.map { |key| key.delete_prefix(Job::JOBS_PREFIX) }
        end
      end
    end
  end
end
