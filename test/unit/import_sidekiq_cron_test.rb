# frozen_string_literal: true

require_relative '../test_helper'
require 'rake'
require 'stringio'
require 'tzinfo'
require_relative '../../lib/wurk/import/sidekiq_cron'

# `rake wurk:import:cron` against real Redis seeded exactly the way sidekiq-cron
# writes its schedule. The seeding mirrors `Sidekiq::Cron::Job#save` and
# `#to_hash` at the pinned v2.4.0 (test/ecosystem/sidekiq-cron/PIN): SADD the
# hash key onto `cron_jobs:<namespace>`, HSET every `to_hash` field with nil
# written as '', args and message as JSON strings.
class ImportSidekiqCronTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_maps_a_namespaced_entry_onto_a_native_loop
    seed('nightly', cron: '0 3 * * *', klass: 'NightlyJob', args: [1, 'two'], queue: 'reports', retry_value: 5)
    entry = sole_entry

    assert_predicate entry, :importable?
    assert_equal %w[default nightly dynamic], [entry.namespace, entry.name, entry.source]
    lp = entry.loop

    assert_equal ['0 3 * * *', 'NightlyJob', nil], [lp.schedule, lp.klass, lp.tz]
    assert_equal({ 'label' => 'nightly', 'args' => [1, 'two'], 'queue' => 'reports', 'retry' => 5 }, lp.options)
    refute_predicate lp, :paused?
  end

  def test_dry_run_writes_nothing_and_apply_registers_the_loop
    key = seed('nightly', cron: '0 3 * * *')
    before = Wurk.redis { |c| c.call('HGETALL', key) }

    out = StringIO.new
    importer.run(apply: false, out: out)

    assert_equal 0, registry_size
    assert_match(/Dry run: nothing was written/, out.string)

    importer.run(apply: true, out: out)
    loops = Wurk::Cron::LoopSet.new.to_a

    assert_equal 1, loops.size
    assert_equal ['0 3 * * *', 'ReportJob', 'nightly'], [loops[0].schedule, loops[0].klass, loops[0].options['label']]
    assert_equal before, Wurk.redis { |c| c.call('HGETALL', key) }, 'sidekiq-cron keys must survive for rollback'
    assert_match(/Registered 1 loop/, out.string)
  end

  def test_reads_the_pre_namespace_legacy_set_and_every_namespace
    seed('old', cron: '*/5 * * * *', set: 'cron_jobs', key: 'cron_job:old', namespace: '')
    seed('a', cron: '0 * * * *', namespace: 'billing')
    seed('b', cron: '30 * * * *', namespace: 'default')

    names = importer.entries.map { |e| [e.namespace, e.name] }.sort

    assert_equal [%w[billing a], %w[default b], %w[default old]], names
  end

  def test_disabled_entry_is_imported_paused
    seed('off', cron: '0 0 * * *', status: 'disabled')

    assert_predicate sole_entry.loop, :paused?
  end

  def test_reimport_is_idempotent_and_keeps_a_dashboard_unpause
    seed('off', cron: '0 0 * * *', status: 'disabled')
    lid = importer.apply!.first.loop.lid
    Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lid}", 'paused', '0') }

    importer.apply!

    assert_equal 1, registry_size
    refute_predicate Wurk::Cron::LoopSet.new.fetch(lid), :paused?
    assert importer.registered?(lid)
  end

  def test_trailing_zone_becomes_tz
    seed('paris', cron: '0 5 * * * Europe/Paris')
    lp = sole_entry.loop

    assert_equal ['0 5 * * *', 'Europe/Paris'], [lp.schedule, lp.tz]
  end

  def test_unknown_zone_is_skipped
    seed('mars', cron: '0 5 * * * Mars/Olympus')

    assert_match(%r{unknown timezone "Mars/Olympus"}, sole_entry.skip_reason)
  end

  def test_fugit_only_schedules_are_skipped_with_a_reason
    seed('secs', cron: '*/30 * * * * *')
    seed('words', cron: 'every day at noon')

    reasons = importer.entries.map(&:skip_reason)

    assert_equal [true, true], reasons.map { |r| r.include?('unsupported schedule') }, reasons.inspect
    assert(importer.entries.none?(&:importable?))
  end

  def test_date_as_argument_and_globalid_args_are_skipped
    seed('dated', cron: '0 1 * * *', date_as_argument: '1')
    seed('gid', cron: '0 2 * * *', args: [{ '_sc_globalid' => 'gid://app/User/1' }])

    reasons = importer.entries.to_h { |e| [e.name, e.skip_reason] }

    assert_match(/date_as_argument/, reasons['dated'])
    assert_match(/GlobalID/, reasons['gid'])
  end

  def test_missing_class_or_cron_is_skipped
    seed('noclass', cron: '0 1 * * *', klass: '')
    seed('nocron', cron: '')

    reasons = importer.entries.to_h { |e| [e.name, e.skip_reason] }

    assert_match(/no class/, reasons['noclass'])
    assert_match(/no cron/, reasons['nocron'])
  end

  def test_args_follow_sidekiq_cron_parsing
    seed('hash', cron: '0 1 * * *', args: JSON.dump({ 'a' => 1 }))
    seed('raw', cron: '0 2 * * *', args: 'not json')
    seed('none', cron: '0 3 * * *', args: '')

    args = importer.entries.to_h { |e| [e.name, e.loop.options['args']] }

    assert_equal({ 'hash' => [{ 'a' => 1 }], 'raw' => ['not json'], 'none' => nil }, args)
  end

  def test_retry_values_are_carried_as_sidekiq_cron_pushes_them
    seed('off', cron: '0 1 * * *', retry_value: false)
    seed('unset', cron: '0 2 * * *', retry_value: nil)
    seed('str', cron: '0 3 * * *', retry_value: '7')
    seed('strf', cron: '0 4 * * *', retry_value: 'false')
    seed('strt', cron: '0 5 * * *', retry_value: 'true')

    opts = importer.entries.to_h { |e| [e.name, e.loop.options] }

    assert_equal [false, false, 7, false], [opts['off']['retry'], opts['unset'].key?('retry'), opts['str']['retry'],
                                            opts['strf']['retry']]
    assert opts['strt']['retry']
  end

  def test_unreadable_message_falls_back_to_worker_defaults
    key = seed('broken', cron: '0 1 * * *')
    Wurk.redis { |c| c.call('HSET', key, 'message', '{nope') }

    refute sole_entry.loop.options.key?('queue')
  end

  def test_odd_shapes_neither_crash_nor_import_garbage
    Wurk.redis { |c| c.call('SET', 'cron_jobs:not-a-set', 'x') }
    seed('odd', cron: '0 1 * * *', retry_value: 'sometimes')
    key = seed('arr', cron: '0 2 * * *')
    Wurk.redis { |c| c.call('HSET', key, 'message', '[1]') }

    opts = importer.entries.to_h { |e| [e.name, e.loop.options] }

    assert_equal 'sometimes', opts['odd']['retry']
    refute opts['arr'].key?('queue')
  end

  def test_active_job_quirks_are_reported_as_warnings
    seed('aj', cron: '0 1 * * *', active_job: '1', queue_name_prefix: 'prod', symbolize_args: '1')

    warnings = sole_entry.warnings

    assert_equal 2, warnings.size
    assert_match(/queue_name_prefix/, warnings[0])
    assert_match(/symbolize_args/, warnings[1])
  end

  def test_run_prints_the_plan_and_a_paste_ready_periodic_block
    seed('nightly', cron: '0 3 * * * UTC', args: [1], queue: 'reports')
    seed('secs', cron: '*/30 * * * * *')
    out = StringIO.new

    importer.run(apply: false, out: out)

    assert_match(/2 \(1 importable, 1 skipped\)/, out.string)
    assert_match(%r{import  default/nightly  "0 3 \* \* \*" ReportJob  -> lid \h{16} \(new\)}, out.string)
    assert_match(%r{skip    default/secs  unsupported schedule}, out.string)
    assert_includes out.string,
                    'mgr.register("0 3 * * *", "ReportJob", label: "nightly", args: [1], queue: "reports", ' \
                    'retry: true, tz: "UTC")'
  end

  def test_the_snippet_registers_the_same_lid_the_import_writes
    seed('nightly', cron: '0 3 * * *', args: [1], queue: 'reports')
    imported = sole_entry.loop

    mgr = Wurk::Cron::Manager.new(prune: false)
    native = mgr.register('0 3 * * *', 'ReportJob', label: 'nightly', args: [1], queue: 'reports', retry: true)

    assert_equal imported.lid, native.lid
  end

  def test_run_marks_registered_loops_and_skips_the_snippet_when_nothing_imports
    seed('nightly', cron: '0 3 * * *')
    importer.apply!
    out = StringIO.new
    importer.run(apply: false, out: out)

    assert_match(/\(already registered\)/, out.string)

    Wurk.redis { |c| c.call('FLUSHDB') }
    seed('secs', cron: '*/30 * * * * *')
    out = StringIO.new
    importer.run(apply: false, out: out)

    refute_match(/config\.periodic/, out.string)
  end

  def test_run_reports_an_empty_redis
    out = StringIO.new

    assert_empty importer.run(apply: true, out: out)
    assert_match(/No sidekiq-cron entries found/, out.string)
  end

  def test_rake_task_imports_only_with_apply
    seed('nightly', cron: '0 3 * * *')
    app = Rake::Application.new
    previous = Rake.application
    Rake.application = app
    load File.expand_path('../../lib/wurk/rake_tasks.rb', __dir__)

    with_env('APPLY' => nil) { capture_io { app['wurk:import:cron'].invoke } }

    assert_equal 0, registry_size

    app['wurk:import:cron'].reenable
    with_env('APPLY' => '1') { capture_io { app['wurk:import:cron'].invoke } }

    assert_equal 1, registry_size
  ensure
    Rake.application = previous
  end

  def test_rake_task_boots_the_rails_environment_first
    booted = false
    app = Rake::Application.new
    previous = Rake.application
    Rake.application = app
    app.define_task(Rake::Task, :environment) { booted = true }
    load File.expand_path('../../lib/wurk/rake_tasks.rb', __dir__)

    capture_io { app['wurk:import:cron'].invoke }

    assert booted
  ensure
    Rake.application = previous
  end

  private

  def importer = Wurk::Import::SidekiqCron.new

  def seed(name, cron:, klass: 'ReportJob', namespace: 'default', args: [], queue: 'default', retry_value: true,
           status: 'enabled', set: nil, key: nil, **extra)
    key ||= "cron_job:#{namespace}:#{name}"
    message = { 'retry' => retry_value, 'queue' => queue, 'class' => klass, 'args' => args }
    fields = {
      'name' => name, 'namespace' => namespace, 'klass' => klass, 'cron' => cron, 'description' => '',
      'source' => 'dynamic', 'args' => args.is_a?(String) ? args : JSON.dump(args), 'date_as_argument' => '0',
      'message' => JSON.dump(message), 'status' => status, 'active_job' => '0', 'queue_name_prefix' => '',
      'queue_name_delimiter' => '', 'retry' => retry_value.nil? ? '' : retry_value.to_s,
      'last_enqueue_time' => '2026-10-04 03:00:00 +0000', 'symbolize_args' => '0'
    }.merge(extra.transform_keys(&:to_s))
    Wurk.redis do |c|
      c.call('SADD', set || "cron_jobs:#{namespace}", key)
      c.call('HSET', key, *fields.flatten)
      c.call('ZADD', "#{key}:enqueued", Time.now.to_f, '2026-10-04 03:00:00 +0000')
    end
    key
  end

  def sole_entry
    entries = importer.entries

    assert_equal 1, entries.size
    entries.first
  end

  def registry_size = Wurk.redis { |c| c.call('SCARD', Wurk::Cron::PERIODIC_KEY) }.to_i

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end
