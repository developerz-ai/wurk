# frozen_string_literal: true

require_relative '../engine_test_helper'

# WURK_VITE_DEV=1 HMR path (issue #181). Vite serves the shell + assets under
# its `base` (== AssetMount::PREFIX), so the controller must fetch the shell
# from that base (not the server root) and repoint the shell's base-relative
# asset URLs at the Vite origin, since the page is served from the host app.
# These cover the URL target + rewrite without needing a running Vite server.
class DashboardDevShellTest < Wurk::Test::EngineCase
  parallelize_me!

  def test_vite_dev_url_targets_the_asset_base_not_root
    assert_equal "#{Wurk::Engine::AssetMount::PREFIX}/", Wurk::DashboardController::VITE_ASSET_BASE
    assert_equal 'http://localhost:5173/wurk-assets/', Wurk::DashboardController::VITE_DEV_URL
  end

  def test_dev_shell_asset_urls_rewritten_to_vite_origin
    out = rewrite(<<~HTML)
      <script type="module" src="/wurk-assets/@vite/client"></script>
      <script type="module" src="/wurk-assets/src/main.tsx"></script>
    HTML

    assert_includes out, 'src="http://localhost:5173/wurk-assets/@vite/client"'
    assert_includes out, 'src="http://localhost:5173/wurk-assets/src/main.tsx"'
    refute_includes out, 'src="/wurk-assets/' # no base-relative entry URLs remain
  end

  def test_dev_shell_leaves_non_asset_urls_untouched
    assert_includes rewrite('<link rel="icon" href="/favicon.png">'), 'href="/favicon.png"'
  end

  private

  def rewrite(html)
    Wurk::DashboardController.new.send(:rewrite_dev_asset_urls, html)
  end
end
