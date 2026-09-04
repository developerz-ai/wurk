# frozen_string_literal: true

require 'minitest/autorun'

# Guards claims in README.md against the rest of the repo's published docs.
# Where README.md claims a sidekiq-* gem runs in CI, a harness must exist on
# disk (test/ecosystem/<gem>/PIN); llms.txt is gated the same way in
# test/unit/llms_txt_test.rb. Reads files and touches no Redis or shared state.
class ReadmeClaimsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  README = File.join(ROOT, 'README.md')

  # Variants used by the README today: "in CI", "in the `ecosystem` CI job",
  # "on every push". Each one means "this gem's upstream suite runs on every
  # PR"; anything in that phrasing has to point at a harness on disk.
  CI_CLAIM = /\b(?:in CI|in the `ecosystem` CI job|on every push)\b/

  def setup
    @text = File.read(README)
  end

  def test_every_sidekiq_gem_claimed_to_run_in_ci_has_a_pin
    # If README.md claims a sidekiq-* gem runs in CI, the claim has to be
    # backed by a harness on disk (test/ecosystem/<gem>/PIN) — otherwise the
    # doc is making a promise CI doesn't keep. Only gems that appear up to
    # the end of the CI_CLAIM match are considered; tracked lists that follow
    # the claim on the same line (e.g. "sidekiq-cron runs in CI; the rest
    # (sidekiq-foo, sidekiq-bar) are tracked in ...") are not CI claims.
    claimed = @text.lines.flat_map do |line|
      match = CI_CLAIM.match(line)
      next [] unless match

      line[0...match.end(0)].scan(/sidekiq-[\w-]+/)
    end.uniq

    missing = claimed.reject { |gem| File.file?(File.join(ROOT, 'test', 'ecosystem', gem, 'PIN')) }

    assert_empty missing,
                 'README.md claims these run in CI but no test/ecosystem/<gem>/PIN ' \
                 "exists on disk: #{missing.join(', ')}"
  end
end
