# frozen_string_literal: true

require_relative '../test_helper'
# Not `require 'sidekiq/testing'`: like upstream it turns fake mode on for the
# whole process at load, and every class later dealt to this worker would push
# into fake queues. Sidekiq::Testing is already defined through the compat layer.

# Sidekiq surfaces a migrating app leans on that worked but had no test of
# their own: a `Sidekiq::Client.prepend` that overrides `push_bulk`,
# `Sidekiq::Queues.jobs_by_class` under the fake test mode, and an empty
# `SIDEKIQ_PRELOAD` turning the swarm's Bundler preload off (Ent §7.2).
class DropInSurfaceTest < Wurk::Test::UnitCase
  class BulkJob
    include Sidekiq::Job

    sidekiq_options queue: 'drop_in_bulk'
    def perform(*); end
  end

  class OtherJob
    include Sidekiq::Job

    def perform(*); end
  end

  # An app-level `Sidekiq::Client.prepend` (tenant tagging, audit logs). The
  # prepend is process-global and cannot be undone, so it acts only while a
  # test arms it.
  module TagBulkPush
    ARMED = :drop_in_surface_tag_bulk

    def push_bulk(items)
      return super unless Thread.current[ARMED]

      Thread.current[ARMED] << items['class']
      super(items.merge('tenant' => 'acme'))
    end
  end
  Sidekiq::Client.prepend(TagBulkPush)

  def teardown
    Thread.current[TagBulkPush::ARMED] = nil
    Wurk::Testing.disable!
    Wurk::Queues.clear_all
    Thread.current[Wurk::Testing::THREAD_KEY] = nil
  ensure
    super
  end

  def test_a_prepended_push_bulk_sees_perform_bulk_and_its_changes_reach_redis
    seen = Thread.current[TagBulkPush::ARMED] = []

    jids = BulkJob.perform_bulk([[1], [2]])

    assert_equal [BulkJob], seen
    assert_equal 2, jids.size
    payloads = Wurk.redis { |c| c.call('LRANGE', 'queue:drop_in_bulk', 0, -1) }.map { |j| JSON.parse(j) }

    assert_equal(%w[acme acme], payloads.map { |p| p['tenant'] })
  end

  def test_a_prepended_push_bulk_sees_the_class_level_client_call
    seen = Thread.current[TagBulkPush::ARMED] = []

    Sidekiq::Client.push_bulk('class' => BulkJob, 'args' => [[3]])

    assert_equal [BulkJob], seen
  end

  def test_jobs_by_class_groups_fake_mode_jobs_by_class_name
    Sidekiq::Testing.fake! do
      BulkJob.perform_async(1)
      BulkJob.perform_async(2)
      OtherJob.perform_async(3)
    end

    by_class = Sidekiq::Queues.jobs_by_class

    assert_equal([[1], [2]], by_class[BulkJob.name].map { |j| j['args'] })
    assert_equal([[3]], by_class[OtherJob.name].map { |j| j['args'] })
  end

  def test_an_empty_sidekiq_preload_disables_the_bundler_preload
    cli = Wurk::CLI.new

    with_env('WURK_PRELOAD' => nil, 'SIDEKIQ_PRELOAD' => '') do
      assert_empty cli.send(:preload_groups)
    end
  end

  private

  def with_env(vars)
    prev = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    prev.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
