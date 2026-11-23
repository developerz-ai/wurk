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

  def get(path, query = '', method: 'GET')
    env = { 'REQUEST_METHOD' => method, 'QUERY_STRING' => query, 'rack.input' => StringIO.new,
            'rack.url_scheme' => 'http', 'HTTP_HOST' => 'example.org' }
    Wurk::Web::Extension::Renderer.call(name: @name, method: method, subpath: path, env: env, mount: '/wurk')
  end

  def post(path) = get(path, method: 'POST')

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
    status, headers, = post("/locks/#{one['lock_digest']}/jobs/#{one['jid']}/delete")

    assert_includes [302, 303], status
    assert_match(%r{locks/uniquejobs:}, headers['Location'] || headers['location'])
    assert_empty UJ::Lock.new(one['lock_digest']).locked_jids
    post("/locks/#{two['lock_digest']}/delete")

    assert_nil UJ::Digests.new.score(two['lock_digest'])
    lock!(3)
    post('/locks/delete_all')

    assert_equal 0, UJ::Digests.new.count
  end

  # A GET deletes nothing: the dashboard's read-only mode and same-origin
  # check guard POSTs, and a GET can come from a link or an image anywhere.
  def test_every_delete_is_a_post_and_a_get_deletes_nothing
    job = lock!(1)
    paths = ["/locks/#{job['lock_digest']}/jobs/#{job['jid']}/delete", "/locks/#{job['lock_digest']}/delete",
             '/locks/delete_all', '/changelogs/delete_all']

    # GET /locks/delete_all is the lock page of a digest named delete_all.
    paths.each { |path| refute_includes [302, 303], get(path)[0], "GET #{path} acted" }
    assert_equal [job['jid']], UJ::Lock.new(job['lock_digest']).locked_jids
    assert_equal 1, UJ::Digests.new.count
    refute_empty UJ::Changelog.new.entries
    body(get('/locks')).scan(/<form action="[^"]*delete[^"]*" method="(\w+)"/).flatten.each do |verb|
      assert_equal 'post', verb
    end
    assert_includes body(get("/locks/#{job['lock_digest']}")), 'method="post"'
  end

  # The digest is a URL segment and the key the delete unlinks, so a key the
  # tabs do not list is left alone.
  def test_a_delete_of_a_key_that_is_no_lock_leaves_it
    Wurk.redis do |c|
      c.call('LPUSH', 'queue:unique-web', '{}')
      c.call('HSET', 'queue:unique-web:LOCKED', 'jid', '1')
    end
    post('/locks/queue:unique-web/delete')
    post('/locks/queue:unique-web/jobs/jid/delete')

    assert_equal(1, Wurk.redis { |c| c.call('LLEN', 'queue:unique-web') })
    assert_equal(1, Wurk.redis { |c| c.call('HLEN', 'queue:unique-web:LOCKED') })
  ensure
    Wurk.redis { |c| c.call('DEL', 'queue:unique-web', 'queue:unique-web:LOCKED') }
  end

  # One page reads each row's info and locked count in one round trip, and the
  # page size is capped.
  def test_a_page_of_locks_is_read_in_one_pipeline_and_capped
    3.times { |i| lock!(i) }
    _size, _cursor, locks = UJ::Digests.new.page(page_size: 10)
    # Gone from Redis after the page read: what the rows show came with the page.
    Wurk.redis { |c| locks.each { |lock| c.call('DEL', lock.key.info, lock.key.locked) } }

    assert_equal 3, locks.size
    assert_equal(['until_executed'] * 3, locks.map { |lock| lock.info['type'] })
    assert_equal([1, 1, 1], locks.map { |lock| lock.locked.count })
    host = HelperHost.new('count' => '1000000')
    host.page_params

    assert_equal 1_000, host.instance_variable_get(:@count)
  end

  def test_expiring_locks_and_changelogs
    Wurk.redis { |c| c.call('ZADD', 'uniquejobs:expiring_digests', Time.now.to_f + 60, 'uniquejobs:soon') }
    lock!(1)

    assert_includes body(get('/expiring_locks')), 'uniquejobs:soon'
    assert_includes body(get('/changelogs')), 'queue_and_lock.lua'
    post('/changelogs/delete_all')

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

  # The helpers the views call, on the inputs a browser can send: no filter, a
  # zero or negative count, a param outside the gem's allow-list, and every
  # shape of args and timestamp a stored lock can hold.
  class HelperHost
    include Wurk::UniqueJobs::Web::Helpers

    attr_accessor :params

    def initialize(params) = @params = params
    def url_params(key) = @params[key]
    def h(text) = CGI.escapeHTML(text.to_s)
    def truncate(text, max) = text.to_s[0, max]
    def to_display(arg) = arg.inspect
  end

  def test_helpers_default_and_escape_what_a_browser_sends
    host = HelperHost.new('filter' => '', 'count' => '-5', 'cursor' => '7')
    host.page_params

    paging = host.instance_eval { [@filter, @count, @current_cursor, @prev_cursor] }

    assert_equal ['*', 100, 7, 0], paging
    linked = HelperHost.new('filter' => '', 'count' => '-5', 'cursor' => '7', 'evil' => 'x')

    assert_equal 'filter=&count=-5&cursor=8', linked.cparams(cursor: 8)
  end

  def test_helpers_render_every_stored_args_and_time_shape
    host = HelperHost.new({})

    assert_equal 'Invalid job payload, args is nil', host.display_lock_args(nil)
    assert_equal 'Invalid job payload, args must be an Array, not Hash', host.display_lock_args({})
    assert_equal '1, &quot;a&lt;b&quot;', host.display_lock_args([1, 'a<b'])
    assert_equal '&quot;ab', host.display_lock_args(['abc'], 3)
    assert_nil host._safe_relative_time(nil)
    stamp = '2026-11-22T10:00:00Z'

    [Time.utc(2026, 11, 22, 10), Time.utc(2026, 11, 22, 10).to_f, stamp].each do |time|
      assert_includes host._safe_relative_time(time), %(datetime="#{stamp}")
    end
  end
end
