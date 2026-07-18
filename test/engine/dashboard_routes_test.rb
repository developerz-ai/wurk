# frozen_string_literal: true

require_relative '../engine_test_helper'

# Drives Wurk::DashboardController against the booted dummy app. The SPA
# shell (vendor/assets/dashboard/index.html) is a build artifact produced by
# `bin/rake frontend:build` and always carries the `wurk-root` mount point.
#
# We assert against the real shipped file rather than stubbing it. The old
# stub-and-restore mutated that shared file, which raced StaticAssetsTest
# (a concurrent reader, in a separate parallel-runner process where a Mutex
# can't help) and — if a run was interrupted mid-test — could overwrite the
# real build with the stub. Skip instead when no build is present.
class DashboardRoutesTest < Wurk::Test::EngineCase
  parallelize_me!

  INDEX = ::Wurk::Engine.root.join('vendor', 'assets', 'dashboard', 'index.html')

  def setup
    super
    skip 'dashboard build missing (run `bin/rake frontend:build`)' unless INDEX.exist?
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

  # The SPA builds every API URL and its router base from window.__WURK_BASE__,
  # injected from the engine's mount prefix (request.script_name). Proves the
  # dashboard is mount-agnostic: the /sidekiq mount (test/dummy routes) serves
  # the same bundle with its own base, no rebuild.
  def test_spa_shell_injects_the_mount_base
    get '/wurk'

    assert_includes last_response.body, '<script>window.__WURK_BASE__ = "/wurk";</script>'
  end

  def test_spa_shell_injects_a_non_default_mount_base
    get '/sidekiq'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<script>window.__WURK_BASE__ = "/sidekiq";</script>'
    refute_includes last_response.body, 'window.__WURK_BASE__ = "/wurk"'
  end
end
