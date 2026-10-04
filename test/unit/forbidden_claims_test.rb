# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tasks/llms_full'

# The public surfaces outside docs/wiki/ (which wiki_pages_test.rb gates) that
# a reader or an agent treats as the project's pitch: README, the docs site,
# the llms.txt map and its generated full dump, and the gem's own summary.
# CLAUDE.md pillar 3 forbids a "faster" claim on any of them until
# docs/benchmarks.md supports it, and a rule nothing reads only holds until the
# next copy edit. Reads files and touches no Redis or shared state.
class ForbiddenClaimsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)

  FILES = %w[README.md docs/site/llms.txt docs/site/index.html].freeze

  # Wurk is 0.87x-1.02x against stock Sidekiq (docs/benchmarks.md). The honest
  # sentence "Wurk is not currently faster than stock Sidekiq" has to survive,
  # so a sentence is only a claim when nothing in it negates the word. Questions
  # and quoted mentions ('"Faster" is meaningless…') are talk about the claim,
  # not the claim.
  SPEED_CLAIM = /\bfaster\b/i
  # A negation must govern each "faster" itself (within two words before it):
  # "not only free but faster" is still a claim.
  NEGATED_PREFIX = /\b(?:not|no|never|isn't|aren't|nor)\W+(?:\w+\W+){0,2}\z/i

  # No production throughput numbers are published (audit R11). Reintroduce a
  # scale figure only together with the soak numbers in docs/benchmarks.md, and
  # update this guard in the same change.
  SCALE_CLAIM = /millions of jobs|jobs an hour/i

  def test_no_public_surface_claims_wurk_is_faster
    offenders = surfaces.flat_map do |name, text|
      sentences(text).filter_map do |sentence|
        "#{name}: #{sentence[0, 160]}" if speed_claim?(sentence)
      end
    end

    assert_empty offenders,
                 'Wurk is 0.87x-1.02x against stock Sidekiq, so no public surface may claim it is ' \
                 "faster (CLAUDE.md pillar 3, docs/benchmarks.md):\n#{offenders.join("\n")}"
  end

  def test_no_public_surface_claims_an_unpublished_scale_figure
    offenders = surfaces.filter_map { |name, text| name if text.match?(SCALE_CLAIM) }

    assert_empty offenders,
                 'no production throughput numbers are published; drop the scale claim or publish ' \
                 "the numbers in docs/benchmarks.md first: #{offenders.join(', ')}"
  end

  def test_the_guard_still_catches_a_bare_claim
    assert speed_claim?('Faster.'), 'the wiki once shipped "Free forever. Faster."'
    assert speed_claim?('Faster than stock Sidekiq')
    refute speed_claim?('Wurk is not currently faster than stock Sidekiq')
    assert speed_claim?('Wurk is not only free but faster than Sidekiq')
    assert speed_claim?('Wurk is not faster than Sidekiq, but it is faster than Resque')
  end

  private

  def surfaces
    @surfaces ||= FILES.to_h { |rel| [rel, File.read(File.join(ROOT, rel))] }.merge(
      'docs/site/llms-full.txt (generated)' => WurkDocs::LlmsFull.build(ROOT),
      'wurk.gemspec summary/description' => gemspec_pitch
    )
  end

  def gemspec_pitch
    spec = Gem::Specification.load(File.join(ROOT, 'wurk.gemspec'))
    "#{spec.summary}\n#{spec.description}"
  end

  # Link targets and code spans carry paths like plans/…/101-faster-than-sidekiq,
  # which are file names, not prose; HTML tags are markup, not prose.
  def sentences(text)
    text.gsub(/\]\([^)]*\)/, ']').gsub(/`[^`]*`/, '').gsub(/<[^>]+>/, ' ')
        .split(/(?<=[.!?])\s+|\n/)
  end

  def speed_claim?(sentence)
    return false unless sentence.match?(SPEED_CLAIM)
    return false if sentence.rstrip.end_with?('?')

    unquoted = sentence.gsub(/["“][^"”]*["”]/, '')
    unquoted.to_enum(:scan, SPEED_CLAIM).any? { !Regexp.last_match.pre_match.match?(NEGATED_PREFIX) }
  end
end
