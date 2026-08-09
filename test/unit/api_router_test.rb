# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/router'

# Slice 07 — the HTTP API's path table. Not ActionDispatch, because standalone
# mode routes without Rails ever being loaded.
class ApiRouterTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_literal_path_matches_its_handler
    router = Wurk::API::Router.new
    router.get('/queues') { :queues }

    match = router.match('GET', '/queues')

    assert_equal :queues, match.handler.call
    assert_empty match.params
  end

  def test_capture_binds_the_segment_by_name
    router = Wurk::API::Router.new
    router.get('/jobs/:jid') { :job }

    match = router.match('GET', '/jobs/abc123')

    assert_equal({ jid: 'abc123' }, match.params)
  end

  def test_capture_is_percent_decoded
    router = Wurk::API::Router.new
    router.get('/queues/:name') { :queue }

    match = router.match('GET', '/queues/low%2Fpriority')

    assert_equal({ name: 'low/priority' }, match.params)
  end

  def test_capture_does_not_span_a_slash
    router = Wurk::API::Router.new
    router.get('/jobs/:jid') { :job }

    assert_nil router.match('GET', '/jobs/abc/extra').handler
  end

  def test_unknown_path_reports_no_allowed_verbs
    router = Wurk::API::Router.new
    router.get('/jobs') { :jobs }

    match = router.match('GET', '/nope')

    assert_nil match.handler
    assert_empty match.allowed
  end

  def test_known_path_wrong_verb_reports_the_verbs_it_accepts
    router = Wurk::API::Router.new
    router.get('/queues/:name') { :show }
    router.post('/queues/:name') { :update }
    router.delete('/queues/:name') { :destroy }

    match = router.match('PUT', '/queues/default')

    assert_nil match.handler
    assert_equal %w[GET POST DELETE], match.allowed
  end

  def test_head_is_served_by_the_get_route
    router = Wurk::API::Router.new
    router.get('/jobs/:jid') { :job }

    match = router.match('HEAD', '/jobs/abc')

    assert_equal :job, match.handler.call
    assert_equal({ jid: 'abc' }, match.params)
  end

  def test_verbs_are_registered_independently_on_the_same_path
    router = Wurk::API::Router.new
    router.get('/jobs/:jid') { :read }
    router.delete('/jobs/:jid') { :remove }

    assert_equal :read, router.match('GET', '/jobs/x').handler.call
    assert_equal :remove, router.match('DELETE', '/jobs/x').handler.call
  end

  def test_root_pattern_matches_with_and_without_a_trailing_slash
    router = Wurk::API::Router.new
    router.get('/') { :root }

    assert_equal :root, router.match('GET', '').handler.call
    assert_equal :root, router.match('GET', '/').handler.call
  end
end
