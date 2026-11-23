# frozen_string_literal: true

module Wurk
  module SidekiqCron
    class Job
      # The class-level half of `Sidekiq::Cron::Job`: loading a schedule,
      # finding, listing and deleting entries, and the key names.
      module Store
        # `{ name => entry }`. Returns `{ name => [errors] }` for the entries
        # that did not validate; the rest are saved.
        def load_from_hash(hash, options = {})
          load_from_array(hash.map { |name, entry| entry.to_h.merge('name' => name) }, options)
        end

        # Also deletes every `source: schedule` entry the hash no longer names,
        # in any namespace. Entries created at runtime (`dynamic`) are kept.
        def load_from_hash!(hash, options = {})
          destroy_removed_jobs(hash.keys)
          load_from_hash(hash, options)
        end

        def load_from_array(array, options = {})
          array.each_with_object({}) do |entry, errors|
            job = new(entry.to_h.merge(options))
            errors[job.name] = job.errors unless job.save
          end
        end

        def load_from_array!(array, options = {})
          destroy_removed_jobs(array.map { |entry| entry['name'] || entry[:name] })
          load_from_array(array, options)
        end

        def all(namespace = SidekiqCron.configuration.default_namespace)
          hashes = ::Sidekiq.redis do |conn|
            keys = job_keys_from_namespace(namespace, conn)
            conn.pipelined { |pipeline| keys.each { |key| pipeline.hgetall(key) } }
          end
          hashes.filter_map do |hash|
            hash = hash.each_slice(2).to_h if hash.is_a?(::Array)
            new(hash.merge('fetch_missing_args' => false)) unless hash.nil? || hash.empty?
          end
        end

        def count(namespace = SidekiqCron.configuration.default_namespace)
          return Namespace.all_with_count.sum { |row| row[:count] } if namespace == '*'

          ::Sidekiq.redis { |conn| conn.scard(jobs_key(namespace)) }
        end

        def find(name, namespace = SidekiqCron.configuration.default_namespace)
          name = name[:name] || name['name'] if name.is_a?(::Hash)
          return nil unless exists?(name, namespace)

          hash = ::Sidekiq.redis { |conn| conn.hgetall(redis_key(name, namespace)) }
          return nil if hash.nil? || hash.empty?

          job = new(hash)
          job if job.valid?
        end

        def create(hash) = new(hash).save

        def destroy(name, namespace = SidekiqCron.configuration.default_namespace)
          name = name[:name] || name['name'] if name.is_a?(::Hash)
          job = find(name, namespace)
          job ? job.destroy : false
        end

        def destroy_all!
          all.each(&:destroy)
          ::Sidekiq.logger.info { 'Cron Jobs - deleted all jobs' }
        end

        def destroy_removed_jobs(new_job_names)
          current = all('*').select { |job| job.source == 'schedule' }
          removed = current.map(&:name) - new_job_names
          removed.each do |name|
            job = current.find { |candidate| candidate.name == name }
            destroy(job.name, job.namespace)
          end
          removed
        end

        def exists?(name, namespace = SidekiqCron.configuration.default_namespace)
          [true, 1].include?(::Sidekiq.redis { |conn| conn.exists(redis_key(name, namespace)) })
        end

        def jobs_key(namespace = SidekiqCron.configuration.default_namespace)
          "#{JOBS_PREFIX}#{default_if_blank(namespace)}"
        end

        def redis_key(name, namespace = SidekiqCron.configuration.default_namespace)
          "#{JOB_PREFIX}#{default_if_blank(namespace)}:#{name}"
        end

        def job_enqueued_key(name, namespace = SidekiqCron.configuration.default_namespace)
          "#{redis_key(name, namespace)}:enqueued"
        end

        def jid_history_key(name, namespace = SidekiqCron.configuration.default_namespace)
          "#{redis_key(name, namespace)}:jid_history"
        end

        # Entries saved before sidekiq-cron had namespaces sit in one
        # `cron_jobs` SET; the gem's poller moves them into the default
        # namespace when it starts, and so does this one.
        def migrate_old_jobs_if_needed!
          old = ::Sidekiq.redis { |conn| conn.smembers(LEGACY_JOBS_KEY).map { |key| [key, conn.hgetall(key)] } }
          old.each do |key, hash|
            create(hash.to_h.merge('namespace' => SidekiqCron.configuration.default_namespace))
            ::Sidekiq.redis { |conn| conn.srem(LEGACY_JOBS_KEY, key) }
          end
        end

        private

        def job_keys_from_namespace(namespace, conn)
          return conn.smembers(jobs_key(namespace)) unless namespace == '*'

          Namespace.all.flat_map { |name| conn.smembers(jobs_key(name)) }
        end

        def default_if_blank(namespace)
          namespace.nil? || namespace == '' ? SidekiqCron.configuration.default_namespace : namespace
        end
      end
    end
  end
end
