# frozen_string_literal: true

require_relative '../engine_test_helper'

# The two host/server i18n hooks the SPA shell carries: the `data-locale`
# first-paint hint negotiated from Accept-Language, and the `#wurk-i18n` copy
# overrides read by loadHostOverrides(). Mutates the global `Wurk::Web.config`,
# so cannot run in parallel with other classes that share the same singleton.
#
# Asserts against the real shipped shell rather than a stub, for the reason
# spelled out in DashboardRoutesTest: stubbing that file races concurrent
# readers in other runner processes.
class DashboardLocaleTest < Wurk::Test::EngineCase
  INDEX = ::Wurk::Engine.root.join('vendor', 'assets', 'dashboard', 'index.html')
  I18N_SCRIPT = %r{<script type="application/json" id="wurk-i18n">(.*?)</script>}m

  def setup
    super
    skip 'dashboard build missing (run `bin/rake frontend:build`)' unless INDEX.exist?
    Wurk::Web.reset_config!
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def test_accept_language_becomes_the_root_locale_hint
    get_shell('de-DE,de;q=0.9,en;q=0.8')

    assert_includes last_response.body, '<div id="wurk-root" data-locale="de">'
  end

  def test_quality_order_decides_the_hint
    get_shell('de;q=0.4,ja;q=0.9')

    assert_includes last_response.body, 'data-locale="ja"'
  end

  # No hint is the right answer for a language wurk ships nothing for: the SPA
  # falls through to navigator.languages instead of being pinned to English.
  def test_unoffered_language_emits_no_hint
    get_shell('he-IL,he;q=0.9')

    assert_includes last_response.body, '<div id="wurk-root">'
    refute_includes last_response.body, 'data-locale'
  end

  def test_missing_header_emits_no_hint
    get '/wurk'

    assert_equal 200, last_response.status
    refute_includes last_response.body, 'data-locale'
  end

  def test_default_locale_answers_when_the_header_matches_nothing
    Wurk::Web.configure { |c| c.default_locale = 'ja' }
    get_shell('he-IL')

    assert_includes last_response.body, 'data-locale="ja"'
  end

  def test_accept_language_outranks_the_host_default
    Wurk::Web.configure { |c| c.default_locale = 'ja' }
    get_shell('fr-CA,fr;q=0.9')

    assert_includes last_response.body, 'data-locale="fr"'
  end

  def test_narrowed_offered_list_stops_negotiating_the_rest
    Wurk::Web.configure { |c| c.offered_locales = %w[en] }
    get_shell('de-DE,de;q=0.9')

    refute_includes last_response.body, 'data-locale'
  end

  # A host that supplies its own copy for an unshipped locale widens the list;
  # the bundle underneath stays English (deliberate — see i18n/index.ts).
  def test_widened_offered_list_negotiates_a_host_supplied_locale
    Wurk::Web.configure { |c| c.offered_locales = Wurk::Web::Config::BUNDLED_LOCALES + ['he'] }
    get_shell('he-IL,he;q=0.9')

    assert_includes last_response.body, 'data-locale="he"'
  end

  # The negotiator only ever returns a tag from the host's own list, so a
  # hostile header can neither be echoed into the attribute nor break out of it.
  def test_hostile_header_reaches_no_attribute
    get_shell('"><script>alert(1)</script>')

    assert_equal 200, last_response.status
    refute_includes last_response.body, 'alert(1)'
    refute_includes last_response.body, 'data-locale'
  end

  def test_no_i18n_block_without_host_translations
    get '/wurk'

    refute_includes last_response.body, 'wurk-i18n'
  end

  def test_host_translations_are_emitted_as_a_locale_keyed_json_block
    overrides = { 'en' => { 'nav' => { 'queues' => 'Pipelines' } } }
    Wurk::Web.configure { |c| c.translations = overrides }
    get '/wurk'

    assert_equal overrides, JSON.parse(last_response.body[I18N_SCRIPT, 1])
  end

  # JSON-escaping the angle brackets is what keeps a `</script>` inside host
  # copy from closing the block early.
  def test_host_translations_cannot_break_out_of_the_script_tag
    Wurk::Web.configure do |c|
      c.translations = { 'en' => { 'nav' => { 'queues' => '</script><script>alert(1)</script>' } } }
    end
    get '/wurk'

    refute_includes last_response.body, '<script>alert(1)'
    assert_equal '</script><script>alert(1)</script>',
                 JSON.parse(last_response.body[I18N_SCRIPT, 1]).dig('en', 'nav', 'queues')
  end

  def test_mount_base_still_injected_alongside_the_i18n_block
    Wurk::Web.configure { |c| c.translations = { 'en' => { 'nav' => { 'queues' => 'Pipelines' } } } }
    get_shell('de')

    assert_includes last_response.body, '<script>window.__WURK_BASE__ = "/wurk";</script>'
    assert_includes last_response.body, 'data-locale="de"'
    assert_match I18N_SCRIPT, last_response.body
  end

  private

  def get_shell(accept_language)
    get '/wurk', {}, 'HTTP_ACCEPT_LANGUAGE' => accept_language
  end
end
