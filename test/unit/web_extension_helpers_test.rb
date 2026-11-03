# frozen_string_literal: true

require_relative '../test_helper'
require 'rack'
require 'cgi'
require 'erb'
require 'wurk/web/extension'

# The helper surface third-party extensions render with: sidekiq-failures and
# sidekiq-unique-jobs both 500'd on what used to be missing here. Expected values
# are upstream 8.1.5's, observed from outside.
class WebExtensionHelpersTest < Wurk::Test::UnitCase
  module Views
    def self.registered(app)
      app.get('/locals') { erb('<%= url %>/<%= @ivar %>', locals: { url: 'u' }) }
      app.get('/leak') { erb('<%= defined?(options).inspect %>/<%= defined?(content).inspect %>') }
      app.get('/paging') do
        @current_page = 2
        @total_size = 100
        @count = 25
        erb(:_paging, locals: { url: "#{root_path}things" })
      end
      app.get('/job') { erb(:_job_info, locals: { job: Wurk::JobRecord.new(JOB), type: :retry }) }
      app.get('/none') { erb(:_no_such_view) }
      app.post('/back') { redirect_with_query("#{root_path}things") }
      app.get('/filter') { filtering('things') }
      app.get('/render') { render(:erb, '<%= a %>', locals: { a: 'via render' }) }
      app.get('/config') { config.equal?(Wurk::Web.config).to_s }
      app.get('/page') { page('wurk-paged', url_params('page'), 2, reverse: true).inspect }
    end
  end

  JOB = Wurk.dump_json(
    'jid' => 'j1', 'class' => 'SomeJob', 'args' => [1, '<b>'], 'queue' => 'q', 'retry_count' => 2,
    'enqueued_at' => 1_700_000_000_000, 'created_at' => 1_700_000_000_000, 'tag<x>' => 'extra'
  )

  class Bare
    include Wurk::Web::Extension::Helpers

    attr_writer :params

    def params = @params || {}
  end

  def setup
    super
    Wurk::Web.reset_config!
    Wurk::Web.register(Views, name: 'views', tab: 'Views', index: 'locals')
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def get(path, headers = {}) = Wurk::Web.call(::Rack::MockRequest.env_for(path).merge(headers))
  def body_of(path) = get(path)[2].join

  def test_erb_honours_locals
    assert_equal 'u/', body_of('/locals')
  end

  def test_a_view_does_not_see_the_renderers_own_locals
    assert_equal 'nil/nil', body_of('/leak')
  end

  def test_render_passes_locals_through
    assert_equal 'via render', body_of('/render')
  end

  def test_paging_partial_links_the_neighbouring_pages
    html = body_of('/paging?direction=asc')

    assert_includes html, '/things?direction=asc&amp;page=1'
    assert_includes html, '/things?direction=asc&amp;page=3'
    assert_includes html, '/things?direction=asc&amp;page=4'
  end

  def test_job_info_partial_escapes_what_it_shows
    html = body_of('/job')

    assert_includes html, 'SomeJob'
    assert_includes html, 'j1'
    assert_includes html, '&lt;b&gt;'
    assert_includes html, 'tag&lt;x&gt;'
    refute_includes html, '<b>'
    refute_includes html, 'tag<x>'
  end

  def test_an_unknown_view_is_a_controlled_500_not_a_crash
    errors = []
    handler = ->(ex, *) { errors << ex }
    Wurk.configuration.error_handlers << handler

    assert_equal 500, get('/none')[0]
    assert_includes errors.first.message, '_no_such_view'
  ensure
    Wurk.configuration.error_handlers.delete(handler)
  end

  def test_redirect_with_query_keeps_the_referer_query
    headers = { 'HTTP_SEC_FETCH_SITE' => 'same-origin', 'REQUEST_METHOD' => 'POST',
                'HTTP_REFERER' => 'http://example.org/things?page=4&zzz=1' }

    assert_equal '/things?page=4&zzz=1', get('/back', headers)[1]['Location']
  end

  def test_redirect_with_query_without_a_usable_referer
    base = { 'HTTP_SEC_FETCH_SITE' => 'same-origin', 'REQUEST_METHOD' => 'POST' }

    assert_equal '/things', get('/back', base)[1]['Location']
    assert_equal '/things', get('/back', base.merge('HTTP_REFERER' => 'http://bad host/ x'))[1]['Location']
  end

  def test_filtering_posts_to_the_filter_route_and_escapes_the_term
    html = body_of('/filter?substr=%3Cx%3E')

    assert_includes html, 'action="/filter/things"'
    assert_includes html, 'value="&lt;x&gt;"'
  end

  def test_action_exposes_the_web_config
    assert_equal 'true', body_of('/config')
  end

  def test_page_over_a_sorted_set
    Wurk.redis { |c| c.call('ZADD', 'wurk-paged', 1, 'a', 2, 'b', 3, 'c') }

    assert_equal [1, 3, [['c', 3.0], ['b', 2.0]]].inspect, body_of('/page?page=0')
    assert_equal [2, 3, [['a', 1.0]]].inspect, body_of('/page?page=2')
  end

  def test_page_over_a_list_and_a_missing_key
    pager = Object.new.extend(Wurk::Web::Paginator)
    Wurk.redis { |c| c.call('LPUSH', 'wurk-paged-list', 'x', 'y') }

    assert_equal [1, 2, %w[y x]], pager.page('wurk-paged-list')
    assert_equal [1, 0, []], pager.page('wurk-paged-absent')
  end

  def test_page_refuses_any_other_type
    Wurk.redis { |c| c.call('SET', 'wurk-paged-string', 'v') }

    assert_raises(ArgumentError) { Object.new.extend(Wurk::Web::Paginator).page('wurk-paged-string') }
  end

  def test_page_over_a_list_in_reverse
    pager = Object.new.extend(Wurk::Web::Paginator)
    Wurk.redis { |c| c.call('RPUSH', 'wurk-paged-list', 'a', 'b', 'c') }

    assert_equal [1, 3, %w[c b]], pager.page('wurk-paged-list', 1, 2, reverse: true)
    assert_equal [2, 3, %w[a]], pager.page('wurk-paged-list', 2, 2, reverse: true)
  end

  def test_page_items_takes_any_collection
    pager = Object.new.extend(Wurk::Web::Paginator)

    assert_equal [1, 2, [[:a, 1]]], pager.page_items({ a: 1, b: 2 }, 1, 1)
    assert_equal [1, 2, [:a]], pager.page_items(Set[:a, :b], 1, 1)
  end

  def test_truncate_without_a_limit_keeps_everything
    assert_equal 'a' * 3000, Bare.new.truncate('a' * 3000, nil)
  end

  def test_page_items
    pager = Object.new.extend(Wurk::Web::Paginator)

    assert_equal [2, 3, [:c]], pager.page_items(%i[a b c], 2, 2)
    assert_equal [9, 3, []], pager.page_items(%i[a b c], 9, 2)
  end

  def test_key_helpers_round_trip
    bare = Bare.new

    assert_equal '123.5-abc', bare.job_params({ 'jid' => 'abc' }, 123.5)
    assert_equal [123.5, 'abc'], bare.parse_key('123.5-abc')
    assert_equal [123.5, 'abc'], bare.parse_params('123.5-abc')
  end

  def test_query_helpers_keep_only_safe_params
    bare = Bare.new
    bare.params = { page: '9', direction: 'asc', zzz: '1' }

    assert_equal 'page=2&direction=asc', bare.qparams(page: 2, 'x' => 'y z')
    assert_equal 'page=x+y', bare.to_query_string('a' => 1, 'page' => 'x y')
  end

  def test_display_args
    bare = Bare.new

    assert_equal '1, &quot;a&quot;', bare.display_args([1, 'a'])
    assert_equal '&quot;aaaaaaaaaa...', bare.display_args(['a' * 50], 10)
    assert_equal 'Invalid job payload, args is nil', bare.display_args(nil)
    assert_includes bare.display_args('oops'), 'args must be an Array, not String'
    assert_includes bare.display_args(5), 'args must be an Array, not Integer'
    assert_includes bare.display_args({ 'a' => 1 }), 'args must be an Array, not Hash'
  end

  def test_standard_strings_read_as_english
    bare = Bare.new

    assert_equal 'Delete All', bare.t('DeleteAll')
    assert_equal 'Retry Now', bare.t('RetryNow')
    assert_equal 'JID', bare.t('JID')
    assert_equal 'Some key', bare.t('some_key')
  end

  def test_process_level_helpers
    bare = Bare.new

    assert_equal 'ltr', bare.text_direction
    refute_predicate bare, :rtl?
    assert_equal 'en', bare.locale
    assert_kind_of Wurk::Stats, bare.stats
    assert_kind_of Wurk::WorkSet, bare.workset
    assert_kind_of Wurk::ProcessSet, bare.processes
    assert_empty bare.sorted_processes
  end
end
