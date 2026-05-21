# frozen_string_literal: true

require_relative '../engine_test_helper'

# Drives Wurk::DashboardController against the booted dummy app. The SPA
# shell is a literal HTML file that ships in vendor/assets/dashboard at gem
# release time (built from frontend/ via `bin/rake frontend:build`). Tests
# stub it so we don't depend on a real frontend build running first.
#
# Not parallelized: we mutate a shared file under the gem's vendor/ dir.
class DashboardRoutesTest < Wurk::Test::EngineCase
  INDEX = ::Wurk::Engine.root.join('vendor', 'assets', 'dashboard', 'index.html')
  STUB = <<~HTML
    <!doctype html>
    <html><head><title>Wurk</title></head>
    <body><div id="wurk-root"></div></body></html>
  HTML

  def setup
    super
    @prior_contents = INDEX.exist? ? INDEX.read : nil
    INDEX.parent.mkpath
    INDEX.write(STUB)
  end

  def teardown
    if @prior_contents
      INDEX.write(@prior_contents)
    elsif INDEX.exist?
      INDEX.delete
    end
  ensure
    super
  end

  def test_get_wurk_returns_spa_shell
    get '/wurk'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<div id="wurk-root">'
    assert_match %r{text/html}, last_response.content_type.to_s
  end

  def test_unknown_html_path_falls_through_to_spa_shell
    get '/wurk/queues'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<div id="wurk-root">'
  end
end
