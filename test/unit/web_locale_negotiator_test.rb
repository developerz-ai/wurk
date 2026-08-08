# frozen_string_literal: true

require_relative '../test_helper'

# Accept-Language -> the `data-locale` hint the dashboard shell carries.
# Pure function over a header string and the host's offered list, so nothing
# global is touched here.
class WebLocaleNegotiatorTest < Wurk::Test::UnitCase
  parallelize_me!

  OFFERED = Wurk::Web::Config::BUNDLED_LOCALES

  def test_exact_tag_wins
    assert_equal 'de', negotiate('de')
    assert_equal 'pt-BR', negotiate('pt-BR')
  end

  def test_match_is_case_insensitive_and_returns_the_offered_spelling
    assert_equal 'pt-BR', negotiate('PT-br')
    assert_equal 'de', negotiate('DE')
  end

  def test_region_falls_back_to_the_base_subtag
    assert_equal 'es', negotiate('es-419')
    assert_equal 'en', negotiate('en-GB')
  end

  # Same rung as bundleFor()'s regional promotion: a browser asking for plain
  # Portuguese gets the one Portuguese bundle wurk ships.
  def test_bare_subtag_is_promoted_to_a_regional_locale
    assert_equal 'pt-BR', negotiate('pt')
    assert_equal 'zh-CN', negotiate('zh')
    assert_equal 'zh-CN', negotiate('zh-Hant-TW')
  end

  def test_highest_quality_entry_wins_regardless_of_position
    assert_equal 'fr', negotiate('en;q=0.8,fr;q=0.9')
  end

  def test_ties_keep_header_order
    assert_equal 'fr', negotiate('fr,de')
    assert_equal 'de', negotiate('de,fr')
    assert_equal 'de', negotiate('de;q=0.9,fr;q=0.9')
  end

  def test_real_browser_header
    assert_equal 'de', negotiate('de-DE,de;q=0.9,en;q=0.8')
  end

  # q=0 is "not acceptable" — the header explicitly rules that language out.
  def test_zero_quality_is_rejected
    assert_equal 'en', negotiate('de;q=0,en')
    assert_nil negotiate('de;q=0')
  end

  def test_whitespace_and_uppercase_quality_parameters_parse
    assert_equal 'fr', negotiate(' en ; Q=0.4 , fr ; q=0.8 ')
  end

  # A wildcard states no preference, so there is no hint to give; the host
  # default and the browser's own list cover that visitor instead.
  def test_wildcard_is_not_a_preference
    assert_nil negotiate('*')
    assert_nil negotiate('he,*;q=0.5')
  end

  def test_unoffered_language_yields_nothing
    assert_nil negotiate('he-IL,he;q=0.9')
    assert_nil negotiate('de', offered: %w[en])
  end

  def test_blank_header_yields_nothing
    assert_nil negotiate(nil)
    assert_nil negotiate('')
    assert_nil negotiate(',,')
  end

  # The return value is always an entry of `offered`, so header text can never
  # reach the emitted attribute even when the header is hostile.
  def test_header_text_is_never_echoed_back
    assert_nil negotiate('"><script>alert(1)</script>')
    assert_nil negotiate('de<script>')
  end

  # Widening the list is how a host serves a locale wurk ships no bundle for,
  # paired with `translations` copy for it.
  def test_offered_list_is_the_whole_vocabulary
    assert_equal 'he', negotiate('he-IL', offered: OFFERED + ['he'])
    assert_equal 'en', negotiate('de-DE,de;q=0.9,en;q=0.8', offered: %w[en fr])
  end

  private

  def negotiate(header, offered: OFFERED)
    Wurk::Web::LocaleNegotiator.call(header, offered: offered)
  end
end
