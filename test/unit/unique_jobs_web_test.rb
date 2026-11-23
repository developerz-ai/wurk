# frozen_string_literal: true

require_relative '../test_helper'
require 'rack'
require 'wurk/web/extension'
require 'wurk/unique_jobs/web'

# The Locks, Expiring Locks and Changelogs tabs, rendered through the dashboard's
# extension renderer as `require "sidekiq_unique_jobs/web"` registers them.
# Registered under a per-test name and removed in teardown.
class UniqueJobsWebTest < Wurk::Test::UnitCase
  UJ = Wurk::UniqueJobs

  class LockedJob
    include Wurk::Job

    sidekiq_options lock: :until_executed, lock_info: true, lock_ttl: 60
  end

  def setup
    super
    UJ.reset!
    UJ.config.max_history = 10
    @name = "unique-#{Process.pid}-#{object_id}"
    Wurk::Web.config.register_extension(UJ::Web, name: @name, tab: ["Locks #{@name}"], index: ['locks/'])
  end

  def teardown
    Wurk::Web.config.extensions.reject! { |e| e[:name] == @name }
    Wurk::Web.config.tabs.delete("Locks #{@name}")
    UJ.reset!
  ensure
    super
  end

  def lock!(*args)
    job = UJ::Job.prepare('class' => LockedJob.name, 'queue' => 'default', 'args' => args,
                          'jid' => SecureRandom.hex(12), 'lock_info' => true)
    UJ::Locksmith.new(job).lock
    job
  end

  def get(path, query = '')
    env = { 'REQUEST_METHOD' => 'GET', 'QUERY_STRING' => query, 'rack.input' => StringIO.new,
            'rack.url_scheme' => 'http', 'HTTP_HOST' => 'example.org' }
    Wurk::Web::Extension::Renderer.call(name: @name, method: 'GET', subpath: path, env: env, mount: '/wurk')
  end

  def body(response) = Array(response[2]).join

  def test_the_locks_page_lists_digests_and_the_lock_page_shows_one
    job = lock!('<b>x</b>')
    response = get('/locks')

    assert_equal 200, response[0]
    assert_includes body(response), job['lock_digest']
    assert_includes body(response), 'until_executed'

    page = body(get("/locks/#{job['lock_digest']}"))

    assert_includes page, job['jid']
    assert_includes page, 'UniqueJobsWebTest::LockedJob'
    assert_includes page, '&quot;&lt;b&gt;x&lt;/b&gt;&quot;', 'lock args must be escaped'
    refute_includes page, '<b>x</b>'
  end

  def test_filtering_and_paging
    lock!(1)
    lock!(2)

    assert_includes body(get('/locks', 'filter=nomatch*')), 'Locks'
    refute_includes body(get('/locks', 'filter=nomatch*')), 'uniquejobs:'
    assert_includes body(get('/locks', 'count=1')), 'Next 1'
  end

  def test_deleting_a_lock_a_jid_and_everything
    one = lock!(1)
    two = lock!(2)
    status, headers, = get("/locks/#{one['lock_digest']}/jobs/#{one['jid']}/delete")

    assert_includes [302, 303], status
    assert_match(%r{locks/uniquejobs:}, headers['Location'] || headers['location'])
    assert_empty UJ::Lock.new(one['lock_digest']).locked_jids
    get("/locks/#{two['lock_digest']}/delete")

    assert_nil UJ::Digests.new.score(two['lock_digest'])
    lock!(3)
    get('/locks/delete_all')

    assert_equal 0, UJ::Digests.new.count
  end

  def test_expiring_locks_and_changelogs
    Wurk.redis { |c| c.call('ZADD', 'uniquejobs:expiring_digests', Time.now.to_f + 60, 'uniquejobs:soon') }
    lock!(1)

    assert_includes body(get('/expiring_locks')), 'uniquejobs:soon'
    assert_includes body(get('/changelogs')), 'queue_and_lock.lua'
    get('/changelogs/delete_all')

    refute_includes body(get('/changelogs')), 'queue_and_lock.lua'
  end

  def test_a_lock_without_info_says_how_to_turn_it_on
    job = UJ::Job.prepare('class' => 'NoInfo', 'queue' => 'default', 'args' => [1], 'jid' => 'j')
    UJ::Locksmith.new(job).lock

    assert_includes body(get("/locks/#{job['lock_digest']}")), 'SidekiqUniqueJobs.config.lock_info = true'
  end

  def test_requiring_the_gem_path_registers_the_tabs
    reader, writer = IO.pipe
    [reader, writer].each(&:binmode)
    pid = fork do
      reader.close
      require 'sidekiq_unique_jobs/web'
      ext = Wurk::Web.config.extensions.find { |e| e[:name] == 'unique_jobs' }
      writer.write(Marshal.dump([ext && ext[:tab], ext && ext[:extension].name]))
      exit!(0)
    end
    writer.close
    data = reader.read
    Process.wait(pid)

    assert_equal [['Locks', 'Expiring Locks', 'Changelogs'], 'Wurk::UniqueJobs::Web'], Marshal.load(data) # rubocop:disable Security/MarshalLoad -- our own child
  end
end
