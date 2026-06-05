# frozen_string_literal: true

# ActiveJob adapter. Rails resolves `:wurk` to this class via the
# QueueAdapters lookup convention (`const_get("WurkAdapter")`). The file is
# loaded eagerly by lib/wurk/engine.rb so the constant is defined before any
# host app sets `config.active_job.queue_adapter = :wurk`.
#
# Spec: docs/target/sidekiq-free.md §28 (ActiveJob integration).

begin
  gem 'activejob', '>= 7.0'
  require 'active_job'
  require_relative '../../wurk/active_job/wrapper'

  ActiveSupport.on_load(:active_job) do
    # Lets native AJs configure Wurk options directly — `sidekiq_options retry: 3`
    # etc. Skip when already included (e.g. Sidekiq loaded alongside in a mixed
    # codebase mid-migration).
    include Wurk::Job::Options unless respond_to?(:sidekiq_options)
  end

  module ActiveJob
    module QueueAdapters
      # Older Rails ships a built-in placeholder; remove before defining.
      remove_const(:WurkAdapter) if const_defined?(:WurkAdapter, false)

      parent = const_defined?(:AbstractAdapter) ? AbstractAdapter : Object
      class WurkAdapter < parent
        # Class var (not class ivar) so subclasses share the same stop flag —
        # matches Sidekiq exactly, which third-party gems read directly.
        @@stopping = false # rubocop:disable Style/ClassVars

        callback = -> { @@stopping = true } # rubocop:disable Style/ClassVars

        Wurk.configure_client { |config| config.on(:quiet, &callback) }
        Wurk.configure_server { |config| config.on(:quiet, &callback) }

        # Defer enqueue until the surrounding DB transaction commits so we
        # never push a job whose row hasn't landed. Matches Sidekiq.
        def enqueue_after_transaction_commit?
          true
        end

        def enqueue(job)
          wrapper = Sidekiq::ActiveJob::Wrapper.set(
            wrapped: job.class,
            queue: job.queue_name
          )
          job.provider_job_id = wrapper.perform_async(job.serialize)
        end

        def enqueue_at(job, timestamp)
          job.provider_job_id = Sidekiq::ActiveJob::Wrapper.set(
            wrapped: job.class,
            queue: job.queue_name
          ).perform_at(timestamp, job.serialize)
        end

        def enqueue_all(jobs)
          jobs.group_by(&:class).sum { |job_class, group| push_grouped_by_queue(job_class, group) }
        end

        def stopping? = @@stopping

        # Backwards-compat alias. Sidekiq exposes this name for jobs enqueued
        # by very old Rails versions that wrote the older constant in payloads.
        JobWrapper = Sidekiq::ActiveJob::Wrapper

        private

        def push_grouped_by_queue(job_class, group)
          group.group_by(&:queue_name).sum do |queue, same_queue|
            immediate, scheduled = same_queue.partition { |j| j.scheduled_at.nil? }
            count = 0
            count += bulk_push(job_class, queue, immediate, scheduled: false) if immediate.any?
            count += bulk_push(job_class, queue, scheduled, scheduled: true) if scheduled.any?
            count
          end
        end

        def bulk_push(job_class, queue, jobs, scheduled:)
          items = {
            'class' => Sidekiq::ActiveJob::Wrapper,
            'wrapped' => job_class,
            'queue' => queue,
            'args' => jobs.map { |j| [j.serialize] }
          }
          items['at'] = jobs.map { |j| j.scheduled_at&.to_f } if scheduled
          Sidekiq::Client.push_bulk(items).compact.size
        end
      end

      # Drop-in: a migrating app's config almost always still reads
      # `queue_adapter = :sidekiq`, and pillar 1 says it must keep working on a
      # one-line gem swap. Rails resolves `:sidekiq` by const_get'ing
      # `SidekiqAdapter`, whose autoload target runs `gem "sidekiq"; require
      # "sidekiq"` (activejob .../sidekiq_adapter.rb:3-4) — that raises at boot
      # in a wurk-only app where no real sidekiq gem exists.
      #
      # When sidekiq is genuinely absent we pre-empt the autoload with a
      # Wurk-backed adapter (a bare subclass — same enqueue path, same canonical
      # wrapper payload, shared `@@stopping`, inherited `JobWrapper`). When the
      # real sidekiq gem IS bundled (mixed mid-migration) we leave its adapter
      # untouched so a genuine install is never clobbered.
      #
      # `gem "sidekiq"` activates without requiring; Bundler raises Gem::LoadError
      # (or Gem::MissingSpecError, a subclass) when it's not in the bundle. The
      # inline rescue keeps that probe from escaping to the outer handler.
      sidekiq_gem_present =
        begin
          gem 'sidekiq'
          true
        rescue Gem::LoadError
          false
        end

      unless sidekiq_gem_present
        # remove_const drops Rails' pending autoload without firing it, so the
        # `class` keyword below then defines fresh and never triggers the
        # `require "sidekiq"`. Same remove-then-define dance as WurkAdapter.
        remove_const(:SidekiqAdapter) if const_defined?(:SidekiqAdapter, false)

        # Bare subclass: inherits the whole enqueue path, the shared @@stopping
        # flag, and the JobWrapper constant from WurkAdapter unchanged.
        class SidekiqAdapter < WurkAdapter; end
      end
    end
  end
rescue Gem::LoadError
  # ActiveJob not present — adapter unavailable, which matches Sidekiq behavior.
end
