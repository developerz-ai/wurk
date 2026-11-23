# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'tzinfo'
require 'sidekiq/cron'

# Native sidekiq-cron (Wurk::SidekiqCron) against real Redis. The keys and hash
# fields asserted here are sidekiq-cron 2.x's (test/ecosystem/sidekiq-cron/PIN);
# test/ecosystem/sidekiq-cron/interop.rb runs the real gem beside this code.
class SidekiqCronTest < Wurk::Test::UnitCase
  parallelize_me!

  # The gem's `Job#to_hash` keys, in its order.
  GEM_FIELDS = %w[name namespace klass cron description source args date_as_argument message status active_job
                  queue_name_prefix queue_name_delimiter retry last_enqueue_time symbolize_args].freeze

  class Tick
    include Sidekiq::Job

    sidekiq_options queue: 'from_class', retry: 3
  end

  def setup
    super
    Wurk::SidekiqCron.reset!
    Sidekiq::Cron.configure { |c| c.reschedule_grace_period = 300 }
  end

  def teardown
    Wurk::SidekiqCron.reset!
  ensure
    super
  end

  # ---- loading and the keyspace ------------------------------------------

  def test_sidekiq_cron_is_the_native_module_without_the_gem
    assert_same Wurk::SidekiqCron, Sidekiq::Cron
    assert_same Wurk::SidekiqCron::Job, Sidekiq::Cron::Job
    assert_predicate Wurk::SidekiqCron, :active?
  end

  def test_load_writes_the_gem_keyspace
    errors = load_schedule('nightly' => entry)

    assert_empty errors
    assert_equal ['cron_job:default:nightly'], redis('SMEMBERS', 'cron_jobs:default')
    hash = redis('HGETALL', 'cron_job:default:nightly')

    assert_equal GEM_FIELDS.sort, hash.keys.sort
    assert_equal({ 'cron' => '*/5 * * * * America/Caracas', 'klass' => "#{self.class}::Tick", 'status' => 'enabled',
                   'source' => 'schedule', 'args' => '[10]', 'active_job' => '0', 'retry' => '3',
                   'description' => 'every five' },
                 hash.slice('cron', 'klass', 'status', 'source', 'args', 'active_job', 'retry', 'description'))
    assert_equal({ 'retry' => 3, 'queue' => 'low', 'class' => "#{self.class}::Tick", 'args' => [10] },
                 JSON.parse(hash['message']).slice('retry', 'queue', 'class', 'args'))
    assert_equal 1, redis('ZCARD', 'cron_job:default:nightly:enqueued')
  end

  def test_load_reports_invalid_entries_and_saves_the_rest
    errors = load_schedule('ok' => entry, 'natural' => entry('cron' => 'every day at 5pm'),
                           'seconds' => entry('cron' => '*/5 * * * * *'),
                           'zone' => entry('cron' => '0 3 * * * Mars/Base'), 'no_class' => entry('class' => nil))

    assert_equal %w[natural no_class seconds zone], errors.keys.sort
    assert_match(/not a 5-field crontab/, errors['natural'].first)
    assert_match(/not a timezone/, errors['seconds'].first)
    assert_match(/not a timezone/, errors['zone'].first)
    assert_equal ["'klass' (or class) must be set"], errors['no_class']
    assert_equal ['ok'], Sidekiq::Cron::Job.all.map(&:name)
  end

  def test_load_bang_destroys_schedule_entries_the_file_dropped_but_keeps_dynamic_ones
    load_schedule('kept' => entry, 'dropped' => entry)
    Sidekiq::Cron::Job.create(entry.merge('name' => 'runtime'))

    load_schedule('kept' => entry)

    assert_equal %w[kept runtime], Sidekiq::Cron::Job.all.map(&:name).sort
    assert_equal 0, redis('EXISTS', 'cron_job:default:dropped:enqueued')
  end

  def test_load_from_array_bang
    errors = Sidekiq::Cron::Job.load_from_array!([entry.merge('name' => 'a'), entry.merge('name' => 'b')],
                                                 source: 'schedule')

    assert_empty errors
    assert_equal %w[a b], Sidekiq::Cron::Job.all.map(&:name).sort
  end

  # ---- state is keyed by name --------------------------------------------

  def test_a_disabled_entry_stays_disabled_when_its_schedule_is_edited
    load_schedule('nightly' => entry)
    Sidekiq::Cron::Job.find('nightly').disable!

    load_schedule('nightly' => entry('cron' => '0 4 * * * America/Caracas', 'queue' => 'other'))
    job = Sidekiq::Cron::Job.find('nightly')

    assert_equal ['disabled', '0 4 * * * America/Caracas', 'other'], [job.status, job.cron, job.queue_name_with_prefix]
    refute_predicate job, :enabled?
    assert_predicate job, :disabled?
  end

  def test_an_explicit_status_in_the_data_wins_as_in_the_gem
    load_schedule('nightly' => entry('status' => 'disabled'))

    assert_equal 'disabled', Sidekiq::Cron::Job.find('nightly').status
    Sidekiq::Cron::Job.find('nightly').enable!

    assert_equal 'enabled', redis('HGET', 'cron_job:default:nightly', 'status')
  end

  def test_find_exists_count_destroy
    load_schedule('a' => entry, 'b' => entry)

    assert Sidekiq::Cron::Job.exists?('a')
    refute Sidekiq::Cron::Job.exists?('missing')
    assert_nil Sidekiq::Cron::Job.find('missing')
    assert_equal 'a', Sidekiq::Cron::Job.find('name' => 'a').name
    assert_equal 2, Sidekiq::Cron::Job.count
    assert_equal 2, Sidekiq::Cron::Job.count('*')

    assert Sidekiq::Cron::Job.destroy('a')
    refute Sidekiq::Cron::Job.destroy('a')
    assert_equal ['b'], Sidekiq::Cron::Job.all.map(&:name)

    Sidekiq::Cron::Job.destroy_all!

    assert_empty redis('KEYS', 'cron_job*')
  end

  def test_namespaces
    Sidekiq::Cron.configure { |c| c.available_namespaces = :auto }
    Sidekiq::Cron::Job.create(entry.merge('name' => 'a', 'namespace' => 'billing'))

    assert_equal ['cron_job:billing:a'], redis('SMEMBERS', 'cron_jobs:billing')
    assert_empty Sidekiq::Cron::Job.all
    assert_equal ['a'], Sidekiq::Cron::Job.all('*').map(&:name)
    assert_equal %w[billing default], Sidekiq::Cron::Namespace.all.sort
    assert_equal 'a', Sidekiq::Cron::Job.find('a', 'billing').name
  end

  def test_an_unlisted_namespace_falls_back_to_the_default
    job = Sidekiq::Cron::Job.new(entry.merge('name' => 'a', 'namespace' => 'elsewhere'))

    assert_equal 'default', job.namespace
  end

  def test_migrates_pre_namespace_entries
    redis('HSET', 'cron_job:legacy', 'name', 'legacy', 'cron', '* * * * *', 'klass', 'X', 'status', 'disabled')
    redis('SADD', 'cron_jobs', 'cron_job:legacy')

    Sidekiq::Cron::Job.migrate_old_jobs_if_needed!

    assert_equal 'disabled', Sidekiq::Cron::Job.find('legacy').status
    assert_empty redis('SMEMBERS', 'cron_jobs')
  end

  # ---- schedule strings ----------------------------------------------------

  def test_schedule_forms
    assert_equal ['*/5 * * * *', 'America/Caracas'], schedule_parts('*/5 * * * * America/Caracas')
    assert_equal ['0 8 * * 1-5', nil], schedule_parts('0 8 * * MON-fri')
    assert_equal ['0 0 1 1,7 *', nil], schedule_parts('0 0 1 jan,jul *')
    assert_equal ['0 0 * * *', 'America/Bogota'], schedule_parts('@daily America/Bogota')
    assert_raises(ArgumentError) { Wurk::SidekiqCron::Schedule.new('@fortnightly') }
    assert_raises(ArgumentError) { Wurk::SidekiqCron::Schedule.new('0 8 * * blursday') }
    assert_raises(ArgumentError) { Wurk::SidekiqCron::Schedule.new('0 8 * * * UTC extra') }
  end

  # fugit's previous_time: one second back, then whole seconds, so the slot at
  # hh:mm:00 is "previous" from hh:mm:01 on.
  def test_previous_time_matches_fugit_at_the_minute_boundary
    schedule = Wurk::SidekiqCron::Schedule.new('* * * * * UTC')
    slot = Time.utc(2026, 1, 1, 10, 5)

    assert_equal slot - 60, schedule.previous_time(slot + 0.5, 3600)
    assert_equal slot, schedule.previous_time(slot + 1, 3600)
    assert_equal slot, schedule.previous_time(slot + 59.9, 3600)
  end

  def test_previous_time_in_a_zone_and_bounded
    schedule = Wurk::SidekiqCron::Schedule.new('0 6 * * * America/Caracas') # 10:00 UTC

    assert_equal Time.utc(2026, 1, 1, 10), schedule.previous_time(Time.utc(2026, 1, 1, 12), 86_400)
    assert_equal Time.utc(2025, 12, 31, 10), schedule.previous_time(Time.utc(2026, 1, 1, 9), 86_400)
    assert_nil schedule.previous_time(Time.utc(2026, 1, 1, 12), 3600)
    assert_equal Time.utc(2026, 1, 2, 10), schedule.next_time(Time.utc(2026, 1, 1, 12))
  end

  def test_no_zone_is_the_process_local_zone
    with_tz('America/New_York') do
      schedule = Wurk::SidekiqCron::Schedule.new('0 6 * * *')

      assert_nil schedule.zone_name
      assert_equal Time.utc(2026, 1, 1, 11), schedule.previous_time(Time.utc(2026, 1, 1, 12), 86_400)
    end
  end

  # ---- firing ----------------------------------------------------------------

  def test_fires_each_occurrence_once_across_job_objects
    load_schedule('minutely' => entry('cron' => '* * * * * UTC'))
    at = Time.at(((Time.now.to_i / 60) + 60) * 60).utc + 5

    assert fired?('minutely', at)
    refute fired?('minutely', at)
    refute fired?('minutely', at + 30)
    assert fired?('minutely', at + 60)
    assert_equal 2, queued('low')
  end

  def test_does_not_fire_past_the_grace_period
    load_schedule('daily' => entry('cron' => '0 3 * * * UTC'))
    slot = Time.utc(2030, 1, 1, 3)

    refute fired?('daily', slot + 301)
    assert fired?('daily', slot + 299)
  end

  def test_a_new_entry_does_not_fire_the_occurrence_it_was_created_after
    load_schedule('minutely' => entry('cron' => '* * * * * UTC'))

    refute fired?('minutely', Time.now.utc)
  end

  def test_a_disabled_entry_does_not_fire
    load_schedule('minutely' => entry('cron' => '* * * * * UTC', 'status' => 'disabled'))

    refute fired?('minutely', Time.now.utc + 3600)
  end

  def test_enqueue_pushes_the_entry_payload_and_records_history
    load_schedule('minutely' => entry('cron' => '* * * * * UTC', 'args' => [{ 'a' => 1 }], 'retry' => false))
    jid = Sidekiq::Cron::Job.find('minutely').enqueue!
    job = JSON.parse(redis('RPOP', 'queue:low'))

    assert_equal [jid, "#{self.class}::Tick", [{ 'a' => 1 }], false], job.values_at('jid', 'class', 'args', 'retry')
    found = Sidekiq::Cron::Job.find('minutely')

    assert_equal([jid], found.jid_history_from_redis.map { |row| row['jid'] })
    assert_in_delta Time.now.to_i, found.last_enqueue_time.to_i, 5
  end

  def test_the_class_queue_applies_when_the_entry_names_none
    load_schedule('minutely' => entry.except('queue'))
    Sidekiq::Cron::Job.find('minutely').enqueue!

    assert_equal 1, queued('from_class')
  end

  def test_an_unknown_class_is_pushed_by_name
    load_schedule('ghost' => entry('class' => 'NoSuchJobAnywhere', 'queue' => 'ghosts'))
    Sidekiq::Cron::Job.find('ghost').enqueue!

    assert_equal 'NoSuchJobAnywhere', JSON.parse(redis('RPOP', 'queue:ghosts'))['class']
  end

  def test_history_is_capped
    Sidekiq::Cron.configure { |c| c.cron_history_size = 2 }
    load_schedule('minutely' => entry)
    job = Sidekiq::Cron::Job.find('minutely')
    3.times { job.enqueue! }

    assert_equal 2, job.jid_history_from_redis.size
  end

  # ---- poller and launcher -------------------------------------------------

  def test_poller_fires_only_on_the_leader
    load_schedule('minutely' => entry('cron' => '* * * * * UTC'))
    poller = Wurk::SidekiqCron::Poller.new(Wurk.configuration)
    later = Time.now.utc + 3600

    poller.define_singleton_method(:leader?) { false }
    poller.tick(later)

    assert_equal 0, queued('low')
    poller.define_singleton_method(:leader?) { true }
    poller.tick(later)

    assert_equal 1, queued('low')
  end

  def test_one_failing_entry_does_not_stop_the_rest
    load_schedule('a' => entry('cron' => '* * * * * UTC'), 'b' => entry('cron' => '* * * * * UTC'))
    errors = []
    config = Wurk.configuration
    poller = Wurk::SidekiqCron::Poller.new(config)
    poller.define_singleton_method(:handle_exception) { |e, ctx| errors << [e.message, ctx[:name]] }
    failing = Sidekiq::Cron::Job.instance_method(:test_and_enqueue_for_time!)
    Sidekiq::Cron::Job.define_method(:test_and_enqueue_for_time!) do |time|
      name == 'a' ? raise('boom') : failing.bind_call(self, time)
    end

    poller.enqueue(Time.now.utc + 3600)

    assert_equal [%w[boom a]], errors
    assert_equal 1, queued('low')
  ensure
    Sidekiq::Cron::Job.define_method(:test_and_enqueue_for_time!, failing) if failing
  end

  def test_launcher_runs_the_poller_unless_the_interval_is_zero
    assert_instance_of Wurk::SidekiqCron::Poller, Wurk::Launcher.new(Wurk::Configuration.new).sidekiq_cron_poller

    Sidekiq::Cron.configure { |c| c.cron_poll_interval = 0 }

    assert_nil Wurk::Launcher.new(Wurk::Configuration.new).sidekiq_cron_poller
  end

  def test_schedule_loader_reads_the_configured_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'schedule.yaml')
      File.write(path, { 'from_file' => entry.merge('cron' => '<%= "0 3 * * *" %>') }.to_yaml)
      Sidekiq::Cron.configure { |c| c.cron_schedule_file = path.sub(/\.yaml\z/, '.yml') }
      loader = Wurk::SidekiqCron::ScheduleLoader.new

      assert_predicate loader, :has_schedule_file?
      loader.load_schedule
    end

    found = Sidekiq::Cron::Job.find('from_file')

    assert_equal ['0 3 * * *', 'schedule'], [found.cron, found.source]
  end

  def test_the_startup_hook_loads_the_file_unless_disabled
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'schedule.yml')
      File.write(path, { 'from_file' => entry }.to_yaml)
      Sidekiq::Cron.configure do |c|
        c.cron_schedule_file = path
        c.enabled = false
      end
      Wurk::SidekiqCron::ScheduleLoader.on_startup

      refute Sidekiq::Cron::Job.exists?('from_file')
      Sidekiq::Cron.configure { |c| c.enabled = true }
      Wurk::SidekiqCron::ScheduleLoader.on_startup
    end

    assert Sidekiq::Cron::Job.exists?('from_file')
  end

  def test_poller_thread_migrates_legacy_entries_and_stops_on_terminate
    redis('HSET', 'cron_job:legacy', 'name', 'legacy', 'cron', '* * * * *', 'klass', 'X')
    redis('SADD', 'cron_jobs', 'cron_job:legacy')
    poller = Wurk::SidekiqCron::Poller.new(Wurk.configuration)
    thread = poller.start

    assert_same thread, poller.start
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.05 until Sidekiq::Cron::Job.exists?('legacy') || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    assert Sidekiq::Cron::Job.exists?('legacy')
    poller.terminate

    refute_predicate thread, :alive?
  end

  def test_a_failed_migration_is_reported_and_the_poller_keeps_running
    errors = []
    poller = Wurk::SidekiqCron::Poller.new(Wurk.configuration)
    poller.define_singleton_method(:handle_exception) { |e, ctx| errors << [e.message, ctx[:context]] }
    original = Sidekiq::Cron::Job.method(:migrate_old_jobs_if_needed!)
    Sidekiq::Cron::Job.define_singleton_method(:migrate_old_jobs_if_needed!) { raise 'redis gone' }

    poller.send(:migrate)

    assert_equal [['redis gone', 'sidekiq-cron-migrate']], errors
  ensure
    Sidekiq::Cron::Job.define_singleton_method(:migrate_old_jobs_if_needed!, original) if original
  end

  def test_configuration_validates_like_the_gem
    assert_raises(ArgumentError) { Sidekiq::Cron.configure { |c| c.natural_cron_parsing_mode = :loose } }
    assert_raises(ArgumentError) { Sidekiq::Cron.configure { |c| c.cron_poll_process_count = 0 } }
    defaults = Wurk::SidekiqCron::Configuration.new

    assert_equal [30, 10, 60, 'default', 'config/schedule.yml'],
                 [defaults.cron_poll_interval, defaults.cron_history_size, defaults.reschedule_grace_period,
                  defaults.default_namespace, defaults.cron_schedule_file]
  end

  # ---- dashboard -------------------------------------------------------------

  def test_dashboard_rows_and_actions
    load_schedule('odd name/with spaces' => entry)
    row = Wurk::Web::Enterprise::Periodic.rows.find { |r| r[:source] == 'sidekiq-cron' }

    assert_equal ['odd name/with spaces', '*/5 * * * * America/Caracas', 'America/Caracas', false, 'low'],
                 row.values_at(:label, :schedule, :tz, :paused, :queue)
    assert_match(/\Asc-\h+\z/, row[:lid])
    assert Wurk::Web::Enterprise::Periodic.pause(row[:lid])
    assert_equal 'disabled', Sidekiq::Cron::Job.find('odd name/with spaces').status
    assert Wurk::Web::Enterprise::Periodic.unpause(row[:lid])
    jid = Wurk::Web::Enterprise::Periodic.enqueue_now(row[:lid])

    assert_equal [jid], Wurk::Web::Enterprise::Periodic.history(row[:lid]).map(&:last)
    refute Wurk::Web::Enterprise::Periodic.pause('sc-00')
  end

  private

  def entry(extra = {})
    { 'cron' => '*/5 * * * * America/Caracas', 'class' => "#{self.class}::Tick", 'queue' => 'low',
      'active_job' => false, 'description' => 'every five', 'args' => [10] }.merge(extra).compact
  end

  def load_schedule(hash) = Sidekiq::Cron::Job.load_from_hash!(hash, source: 'schedule')

  def fired?(name, at) = !Sidekiq::Cron::Job.find(name).test_and_enqueue_for_time!(at).nil?

  def queued(queue) = redis('LLEN', "queue:#{queue}")

  def redis(*command) = Wurk.redis { |c| c.call(*command) }

  def schedule_parts(string)
    schedule = Wurk::SidekiqCron::Schedule.new(string)
    [schedule.crontab, schedule.zone_name]
  end

  def with_tz(zone)
    previous = ENV.fetch('TZ', nil)
    ENV['TZ'] = zone
    yield
  ensure
    ENV['TZ'] = previous
  end
end
