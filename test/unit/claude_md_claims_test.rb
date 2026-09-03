# frozen_string_literal: true

require 'minitest/autorun'

# Guards claims in CLAUDE.md the same way readme_claims_test.rb gates
# README.md and llms_txt_test.rb gates llms.txt: any sidekiq-* gem claimed
# to pass its suite against Wurk (or to run in CI against Wurk) must point
# at a harness on disk (test/ecosystem/<gem>/PIN). CLAUDE.md is an agent
# steering file, so the bar is the same — a future edit that introduces a
# false claim about a third-party gem's test suite running against Wurk
# should fail this gate, not slip into the file unnoticed. Reads files and
# touches no Redis or shared state.
class ClaudeMdClaimsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  CLAUDE_MD = File.join(ROOT, 'CLAUDE.md')

  # Variants used by CLAUDE.md today: "passes its own test suite against
  # Wurk". Future drift in any "[verb] <word> own test suite against Wurk"
  # phrasing also triggers this regex, so the gate holds as the file
  # evolves. The README/llms.txt alternatives ("in CI", "in the
  # `ecosystem` CI job", "on every push") are included so a copy-paste from
  # those files into CLAUDE.md is gated here too. Tracked additions phrase
  # themselves as "tracked in ..." and do not trigger this regex.
  CI_CLAIM = /\b(?:passes? \w+ own test suite against Wurk|in CI|in the `ecosystem` CI job|on every push)\b/

  def setup
    @text = File.read(CLAUDE_MD)
  end

  def test_every_sidekiq_gem_claimed_to_pass_against_wurk_has_a_pin
    # If CLAUDE.md claims a sidekiq-* gem passes its suite against Wurk
    # (or runs in CI against Wurk), the claim has to be backed by a
    # harness on disk (test/ecosystem/<gem>/PIN) — otherwise the doc is
    # making a promise CI doesn't keep. Only gems that appear up to the
    # end of the CI_CLAIM match are considered; tracked lists that follow
    # the claim on the same line (e.g. "sidekiq-cron passes ...; the rest
    # (sidekiq-foo, sidekiq-bar) are tracked in ...") are not CI claims.
    claimed = @text.lines.flat_map do |line|
      match = CI_CLAIM.match(line)
      next [] unless match

      line[0...match.end(0)].scan(/sidekiq-[\w-]+/)
    end.uniq

    missing = claimed.reject { |gem| File.file?(File.join(ROOT, 'test', 'ecosystem', gem, 'PIN')) }

    assert_empty missing,
                 'CLAUDE.md claims these pass against Wurk but no test/ecosystem/<gem>/PIN ' \
                 "exists on disk: #{missing.join(', ')}"
  end
end
