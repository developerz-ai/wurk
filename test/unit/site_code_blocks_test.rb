# frozen_string_literal: true

require_relative '../test_helper'

# Guards keyboard access to the code snippets on docs/site/index.html.
#
# The page styles `pre { overflow-x: auto }`, which turns EVERY snippet into a
# scroll container as soon as one line is wider than the viewport. The migration
# diff already is — 236px past the edge at 390px wide. A scroll container that
# nothing can focus cannot be scrolled by keyboard at all (WCAG 2.1.1), so the
# content past the edge is simply unreachable without a mouse or a touchscreen.
#
# The fix is `tabindex="0"` on each <pre>, plus a visible focus ring. This test
# exists because the failure is invisible on a desktop viewport, where nothing
# overflows and everything looks fine — so a snippet added without the attribute
# would sail through review and only break for keyboard users on a phone.
class SiteCodeBlocksTest < Minitest::Test
  # Reads one file and touches no Redis or shared state, so it is safe in the
  # parallel runner — matching the other 120 of 124 unit cases.
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  INDEX = File.join(ROOT, 'docs', 'site', 'index.html')

  def setup
    @html = File.read(INDEX)
    # Comments discuss <pre> in prose; scanning them counts a sentence as markup.
    @markup = @html.gsub(/<!--.*?-->/m, '').gsub(%r{/\*.*?\*/}m, '')
  end

  def test_every_code_block_is_keyboard_focusable
    opening_tags = @markup.scan(/<pre\b[^>]*>/)

    refute_empty opening_tags, 'expected the landing page to contain code snippets'

    unfocusable = opening_tags.reject { |tag| tag.include?('tabindex="0"') }

    assert_empty unfocusable,
                 "every <pre> is a horizontal scroll container and must carry tabindex=\"0\" " \
                 "so it can be scrolled by keyboard (WCAG 2.1.1); missing on: #{unfocusable.join(', ')}"
  end

  def test_focused_code_block_shows_a_visible_ring
    # A focus stop with no ring is a cursor that vanishes — half a fix is worse
    # than none, because the tab order grows without telling anyone where it went.
    assert_match(/pre:focus-visible\s*\{[^}]*outline:/, @html,
                 'pre:focus-visible must set a visible outline')
  end
end
