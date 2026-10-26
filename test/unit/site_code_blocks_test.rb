# frozen_string_literal: true

require_relative '../test_helper'

# Guards keyboard access to the code snippets on every docs/site page.
#
# The pages style `pre { overflow-x: auto }`, which turns EVERY snippet into a
# scroll container as soon as one line is wider than the viewport. The migration
# diff on index.html already is — 236px past the edge at 390px wide. A scroll
# container that nothing can focus cannot be scrolled by keyboard at all
# (WCAG 2.1.1), so the content past the edge is simply unreachable without a
# mouse or a touchscreen.
#
# The fix is `tabindex="0"` on each <pre>, plus a visible focus ring. This test
# exists because the failure is invisible on a desktop viewport, where nothing
# overflows and everything looks fine — so a snippet added without the attribute
# would sail through review and only break for keyboard users on a phone.
#
# Pages are enumerated by glob, not named one by one: a second page added under
# docs/site/ must fall under this gate the day it exists.
class SiteCodeBlocksTest < Minitest::Test
  # Reads files and touches no Redis or shared state, so it is safe in the
  # parallel runner — matching the other 120 of 124 unit cases.
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  PAGES = Dir.glob(File.join(ROOT, 'docs', 'site', '*.html')).freeze

  def test_every_site_page_has_keyboard_focusable_code_blocks
    refute_empty PAGES, 'expected at least one page under docs/site/'

    PAGES.each do |path|
      html = File.read(path)
      # Comments discuss <pre> in prose; scanning them counts a sentence as markup.
      markup = html.gsub(/<!--.*?-->/m, '').gsub(%r{/\*.*?\*/}m, '')

      assert_code_blocks_keyboard_focusable(path, html, markup)
      assert_focus_ring_styled(path, html, markup)
    end
  end

  # Regression: the gate must catch a NEW page that violates either rule, so a
  # future page can never bypass it by simply existing outside a hardcoded list.
  def test_gate_catches_violations_on_a_synthetic_page
    no_tabindex = '<style>pre:focus-visible { outline: 2px solid; }</style><pre>code</pre>'
    error = assert_raises(Minitest::Assertion) do
      assert_code_blocks_keyboard_focusable('synthetic/no_tabindex.html', no_tabindex, no_tabindex)
    end
    assert_match(/tabindex="0"/, error.message)
    assert_includes error.message, 'no_tabindex.html'

    no_focus_ring = '<style>pre { overflow-x: auto; }</style><pre tabindex="0">code</pre>'
    error = assert_raises(Minitest::Assertion) do
      assert_focus_ring_styled('synthetic/no_focus_ring.html', no_focus_ring, no_focus_ring)
    end
    assert_match(/pre:focus-visible/, error.message)
    assert_includes error.message, 'no_focus_ring.html'
  end

  private

  def assert_code_blocks_keyboard_focusable(path, _html, markup)
    opening_tags = markup.scan(/<pre\b[^>]*>/)

    refute_empty opening_tags, "expected #{path} to contain code snippets"

    unfocusable = opening_tags.reject { |tag| tag.include?('tabindex="0"') }

    assert_empty unfocusable,
                 "#{path}: every <pre> is a horizontal scroll container and must carry " \
                 'tabindex="0" so it can be scrolled by keyboard (WCAG 2.1.1); ' \
                 "missing on: #{unfocusable.join(', ')}"
  end

  def assert_focus_ring_styled(path, html, _markup)
    # A focus stop with no ring is a cursor that vanishes — half a fix is worse
    # than none, because the tab order grows without telling anyone where it went.
    assert_match(/pre:focus-visible\s*\{[^}]*outline:/, html,
                 "#{path}: pre:focus-visible must set a visible outline")
  end
end
