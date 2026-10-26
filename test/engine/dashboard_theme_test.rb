# frozen_string_literal: true

require_relative '../engine_test_helper'

# The host-configured theme default the SPA shell carries. Unlike the locale
# hint, it lands at the top of <head>: the shell's pre-paint script reads it
# before the stylesheet loads, and a payload injected before </head> would
# arrive after that script had already resolved without it.
#
# Mutates the global `Wurk::Web.config`, so cannot run in parallel with other
# classes sharing that singleton. Asserts against the real shipped shell for the
# reason spelled out in DashboardRoutesTest.
class DashboardThemeTest < Wurk::Test::EngineCase
  INDEX = ::Wurk::Engine.root.join('vendor', 'assets', 'dashboard', 'index.html')
  THEME_SCRIPT = %r{<script>window\.__WURK_THEME__ = (.*?);</script>}

  def setup
    super
    @previous_theme_env = ENV.delete('WURK_WEB_DEFAULT_THEME')
    Wurk::Web.reset_config!
    skip 'dashboard build missing (run `bin/rake frontend:build`)' unless INDEX.exist?
  end

  def teardown
    Wurk::Web.reset_config!
    ENV['WURK_WEB_DEFAULT_THEME'] = @previous_theme_env
    super
  end

  # No config is the common case, and it has to stay silent: the SPA's own
  # default is 'system', which follows the visitor's OS. Matched on the script
  # tag rather than the name — the pre-paint script reads that global itself.
  def test_no_hint_without_a_configured_default
    get '/wurk'

    assert_equal 200, last_response.status
    refute_match THEME_SCRIPT, last_response.body
  end

  def test_env_default_is_emitted_before_pre_paint_without_server_configuration
    %w[light dark system].each do |theme|
      with_env('WURK_WEB_DEFAULT_THEME', theme) do
        Wurk::Web.reset_config!
        get '/wurk'

        assert_equal 200, last_response.status
        assert_equal theme.to_json, last_response.body[THEME_SCRIPT, 1]
        assert_operator last_response.body.index(THEME_SCRIPT), :<,
                        last_response.body.index("localStorage.getItem('wurk.theme')")
      end
    end
  end

  def test_web_configure_overrides_env_default_and_nil_removes_hint
    with_env('WURK_WEB_DEFAULT_THEME', 'dark') do
      assert_equal 'dark', Wurk::Web.config.default_theme

      Wurk::Web.configure { |c| c.default_theme = 'light' }
      get '/wurk'

      assert_equal 200, last_response.status
      assert_equal '"light"', last_response.body[THEME_SCRIPT, 1]

      Wurk::Web.configure { |c| c.default_theme = nil }
      get '/wurk'

      assert_equal 200, last_response.status
      refute_match THEME_SCRIPT, last_response.body
    end
  end

  def test_configured_default_is_emitted
    Wurk::Web.configure { |c| c.default_theme = 'light' }
    get '/wurk'

    assert_equal '"light"', last_response.body[THEME_SCRIPT, 1]
  end

  # Ordering is the whole point of the separate injection point — the pre-paint
  # script cannot read a global declared after it.
  def test_hint_precedes_the_pre_paint_script
    Wurk::Web.configure { |c| c.default_theme = 'dark' }
    get '/wurk'

    assert_operator last_response.body.index(THEME_SCRIPT), :<,
                    last_response.body.index("localStorage.getItem('wurk.theme')")
  end

  def test_hint_coexists_with_the_mount_base_and_locale_injections
    Wurk::Web.configure do |c|
      c.default_theme = 'light'
      c.default_locale = 'ja'
    end
    get '/wurk'

    assert_includes last_response.body, '<script>window.__WURK_BASE__ = "/wurk";</script>'
    assert_includes last_response.body, 'data-locale="ja"'
    assert_equal '"light"', last_response.body[THEME_SCRIPT, 1]
  end

  private

  def with_env(key, value)
    previous = ENV.fetch(key, nil)
    ENV[key] = value
    yield
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
    Wurk::Web.reset_config!
  end
end
