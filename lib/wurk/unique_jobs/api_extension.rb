# frozen_string_literal: true

module Wurk
  module UniqueJobs
    # A job deleted through the API (dashboard, `Sidekiq::Queue#clear`,
    # `ScheduledSet#delete`, ...) gives its lock back, as the gem's
    # `sidekiq_unique_ext` makes it. Prepended once, when this module loads.
    # The gem recomputes a digest for every deleted job; a payload that carries
    # no `lock_digest` never took a lock, so it costs nothing here.
    module APIExtension
      def self.release(item)
        Unlockable.delete!(item) if item.is_a?(::Hash) && item[LOCK_DIGEST]
      end

      # A member that is not a job holds no lock; the set's own handling of it
      # (wurk moves it to the dead set) goes on undisturbed.
      def self.release_raw(payload)
        release(Wurk.load_json(payload))
      rescue ::JSON::ParserError, ::EncodingError
        nil
      end

      module SortedEntry
        def delete
          APIExtension.release(item) if super
          item
        end

        private

        def remove_job
          super do |message|
            APIExtension.release_raw(message)
            yield message
          end
        end
      end

      module ScheduledSet
        def delete(score, job_id)
          entry = find_job(job_id)
          APIExtension.release(entry.item) if super && entry
          entry
        end
      end

      module JobRecord
        def delete
          APIExtension.release(item)
          super
        end
      end

      # The gem deletes entry by entry before clearing, an LREM per job; the
      # locks are what it was after, so only those are released, then the clear.
      module ClearEach
        def clear
          each { |record| APIExtension.release(record.item) }
          super
        end
      end

      module JobSet
        def delete_by_value(name, value)
          removed = super
          APIExtension.release_raw(value) if removed
          removed
        end
      end

      def self.install
        Wurk::SortedEntry.prepend(SortedEntry)
        Wurk::ScheduledSet.prepend(ScheduledSet)
        Wurk::JobRecord.prepend(JobRecord)
        Wurk::Queue.prepend(ClearEach)
        Wurk::JobSet.prepend(ClearEach, JobSet)
      end
    end
  end
end
