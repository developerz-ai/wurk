# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/router'

# Slice 07 — the HTTP API's path table. Not ActionDispatch, because standalone
# mode routes without Rails ever being loaded.
class ApiRouterTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_literal_path_matches_its_handler
    router = Wurk::API::Router.new
    router.get('/queues', scope: :read) { :queues }

    match = router.match('GET', '/queues')

    assert_equal :queues, match.handler.call
    assert_empty match.params
  end

  def test_capture_binds_the_segment_by_name
    router = Wurk::API::Router.new
    router.get('/jobs/:jid', scope: :read) { :job }

    match = router.match('GET', '/jobs/abc123')

    assert_equal({ jid: 'abc123' }, match.params)
  end

  def test_capture_is_percent_decoded
    router = Wurk::API::Router.new
    router.get('/queues/:name', scope: :read) { :queue }

    match = router.match('GET', '/queues/low%2Fpriority')

    assert_equal({ name: 'low/priority' }, match.params)
  end

  def test_capture_does_not_span_a_slash
    router = Wurk::API::Router.new
    router.get('/jobs/:jid', scope: :read) { :job }

    assert_nil router.match('GET', '/jobs/abc/extra').handler
  end

  def test_unknown_path_reports_no_allowed_verbs
    router = Wurk::API::Router.new
    router.get('/jobs', scope: :read) { :jobs }

    match = router.match('GET', '/nope')

    assert_nil match.handler
    assert_empty match.allowed
  end

  def test_known_path_wrong_verb_reports_the_verbs_it_accepts
    router = Wurk::API::Router.new
    router.get('/queues/:name', scope: :read) { :show }
    router.post('/queues/:name', scope: :read) { :update }
    router.delete('/queues/:name', scope: :read) { :destroy }

    match = router.match('PUT', '/queues/default')

    assert_nil match.handler
    assert_equal %w[GET POST DELETE], match.allowed
  end

  def test_head_is_served_by_the_get_route
    router = Wurk::API::Router.new
    router.get('/jobs/:jid', scope: :read) { :job }

    match = router.match('HEAD', '/jobs/abc')

    assert_equal :job, match.handler.call
    assert_equal({ jid: 'abc' }, match.params)
  end

  def test_verbs_are_registered_independently_on_the_same_path
    router = Wurk::API::Router.new
    router.get('/jobs/:jid', scope: :read) { :read }
    router.delete('/jobs/:jid', scope: :read) { :remove }

    assert_equal :read, router.match('GET', '/jobs/x').handler.call
    assert_equal :remove, router.match('DELETE', '/jobs/x').handler.call
  end

  def test_root_pattern_matches_with_and_without_a_trailing_slash
    router = Wurk::API::Router.new
    router.get('/', scope: :read) { :root }

    assert_equal :root, router.match('GET', '').handler.call
    assert_equal :root, router.match('GET', '/').handler.call
  end

  # The router records the scope; App#dispatch enforces it. A match that lost
  # it would silently open the route to every token.
  def test_a_match_carries_the_scope_its_route_declared
    router = Wurk::API::Router.new
    router.get('/jobs/:jid', scope: :read) { :read }
    router.delete('/jobs/:jid', scope: :admin) { :remove }

    assert_equal :read, router.match('GET', '/jobs/x').scope
    assert_equal :admin, router.match('DELETE', '/jobs/x').scope
  end

  # Required keyword plus a closed vocabulary: adding an endpoint without
  # deciding who may call it, or with a misspelled scope, fails at draw time.
  def test_a_route_needs_a_scope_from_the_known_set
    router = Wurk::API::Router.new

    assert_raises(ArgumentError) { router.get('/x', scope: :reed) { :x } }
    assert_raises(ArgumentError) { router.get('/x', scope: nil) { :x } }
    assert_raises(ArgumentError) { router.post('/x', scope: 'read') { :x } }
    assert_raises(ArgumentError) { router.delete('/x', scope: :reed) { :x } }
    assert_raises(ArgumentError) { router.get('/x') { :x } }
  end
end
