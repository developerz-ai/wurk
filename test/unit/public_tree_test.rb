# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'

# The public tree names nothing private. This repository is public, so every tracked file is a
# public document: no host on our own domain that only our infrastructure uses, no private
# repository or its tracker, no one's home directory, no name of the setup mode that once wrote
# agent files, and none of the private words (an adopter, a private product).
#
# The private words are never in this file, whole or in parts: two quoted fragments joined in a
# public file are the word to anyone who reads it. They come from the PUBLIC_TREE_PRIVATE_WORDS CI
# secret (comma- or newline-separated). A run without it (a fork's PR, Dependabot's, a local run)
# says it skipped them; this repository's own CI runs set PUBLIC_TREE_PRIVATE_WORDS_REQUIRED=1,
# where an empty secret fails. The setup mode's name is already public, so it is assembled here.
#
# The scan reads `git ls-files`, proves it read this file and counts what it read, so a wrong root
# is a failure, never a pass over nothing. A failure names the file and the rule, never the
# matched text: CI logs are public. Each rule is proven to fire below before it is trusted.
#
# `docs/plans/` is skipped by the private-repository and private-word rules until its adopter
# slices are anonymised (tracked in the issue this guard closes); every other rule reads it.
class PublicTreeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SELF = 'test/unit/public_tree_test.rb'
  MIN_TRACKED = 1000

  DOMAIN = %w[developerz ai].join('.')
  # The public site, the public demo, and the platform API the ecosystem workflow posts to.
  PUBLIC_HOSTS = ["www.#{DOMAIN}", "wurk.demo.#{DOMAIN}", "api.#{DOMAIN}"].freeze
  # A host starts after a delimiter, so a URL-encoded badge label (`live%20demo-<host>`) is not one.
  OWN_HOST = /(?<![%\w.-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+#{Regexp.escape(DOMAIN)}\b/i
  # The organisation's public repositories this tree may name.
  PUBLIC_REPOS = %w[wurk ultimate ui-debugger-mcp db-mcp-gateway ai-task-master multi-ai-router
                    claudes ts23d mcp-ssh].freeze
  # A GitHub reference to an org repository: after `github.com/`, or bare. A registry path
  # (`registry.example.com/<org>/<image>`) is an image, not a repository.
  ORG_REPO = %r{(?:github\.com/|(?<![\w./-]))developerz-ai/([\w.-]+)}i
  # A bare tracker reference to one of the org's private repositories, `name#12` or `name #12`;
  # `dz` is the platform tracker's shorthand.
  PRIVATE_TRACKERS = %w[infrastructure developerz.ai dz].freeze
  BARE_TRACKER = %r{(?<![\w./-])(?:#{PRIVATE_TRACKERS.map { |n| Regexp.escape(n) }.join('|')}) ?#\d}i
  # CI's and the systemd example's generic service users are nobody's machine.
  HOME_PATH = %r{(?:^|[^\w.-])/(?:home|Users)/(?!runner\b|user\b|app\b|deploy\b)[\w.-]+}
  # The parts are listed backwards so no literal here reads as the name.
  SETUP_MODE = /(?<![a-z0-9])#{%w[runner dz].reverse.join('[-_ ]?')}(?![a-z0-9])/i
  PRIVATE_WORDS_ENV = 'PUBLIC_TREE_PRIVATE_WORDS'
  REQUIRED_ENV = 'PUBLIC_TREE_PRIVATE_WORDS_REQUIRED'
  PLANS = 'docs/plans/'

  def self.private_words(raw)
    raw.to_s.split(/[,\n]/).map(&:strip).reject(&:empty?).map { |w| /#{Regexp.escape(w)}/i }
  end

  # The private words for this run, or the reason the run must fail.
  def self.private_words_for_run(raw, required:)
    words = private_words(raw)
    if words.empty? && required
      raise ArgumentError,
            "#{PRIVATE_WORDS_ENV} is empty, and #{REQUIRED_ENV}=1 says this run must check the private words"
    end

    words
  end

  # The names of every rule `text` breaks at `path`. Never the matched text.
  def self.violations(path, text, words)
    rules = []
    rules << 'internal host on our own domain' if text.scan(OWN_HOST).any? { |h| !PUBLIC_HOSTS.include?(h.downcase) }
    rules << 'setup-mode name' if text.match?(SETUP_MODE)
    rules << "someone's home directory" if text.match?(HOME_PATH)
    return rules if path.start_with?(PLANS)

    rules + private_rules(text, words)
  end

  # The rules `docs/plans/` is spared for now: a private repository and a private word.
  def self.private_rules(text, words)
    rules = []
    private_repo = text.scan(ORG_REPO).flatten.any? do |name|
      !PUBLIC_REPOS.include?(name.downcase.sub(/\.git\z/, '').sub(/[.]+\z/, ''))
    end
    rules << 'private repository' if private_repo || text.match?(BARE_TRACKER)
    rules << 'private word (from the secret)' if words.any? { |w| text.match?(w) }
    rules
  end

  # Every tracked path, from git itself, after checking git answers for this tree.
  def self.tracked_files
    top, status = Open3.capture2('git', 'rev-parse', '--show-toplevel', chdir: ROOT)
    raise 'git rev-parse --show-toplevel failed' unless status.success?
    raise "git answers for another repository's tree" unless File.realpath(ROOT) == File.realpath(top.strip)

    out, status = Open3.capture2('git', 'ls-files', '-z', chdir: ROOT)
    raise 'git ls-files failed' unless status.success?

    out.split("\0").reject(&:empty?)
  end

  def test_no_tracked_file_names_anything_private
    words = self.class.private_words_for_run(ENV.fetch(PRIVATE_WORDS_ENV, nil), required: ENV[REQUIRED_ENV] == '1')
    warn "public-tree: #{PRIVATE_WORDS_ENV} is unset, private words not checked" if words.empty?
    files = self.class.tracked_files

    assert_includes files, SELF, 'the scan does not see this file, so its root is wrong'
    read = 0
    failures = files.flat_map do |path|
      full = File.join(ROOT, path)
      next [] unless File.file?(full)

      bytes = File.binread(full)
      next [] if bytes.include?("\0")

      read += 1
      self.class.violations(path, bytes.force_encoding('UTF-8').scrub, words).map { |rule| "#{path}: #{rule}" }
    end
    warn "public-tree: read #{read} of #{files.size} tracked files, #{words.size} private words"

    assert_operator read, :>=, MIN_TRACKED, "read only #{read} tracked files"
    assert_empty failures,
                 "tracked files name something private (rule per file, value withheld):\n#{failures.join("\n")}"
  end

  # The rules, proven to fire before they are trusted on the tree.

  def test_internal_host_fires_and_the_public_ones_pass
    assert_equal ['internal host on our own domain'], self.class.violations('a.md', "https://mcp.#{DOMAIN}/v1", [])
    assert_empty self.class.violations('a.md', "https://wurk.demo.#{DOMAIN} and https://www.#{DOMAIN}", [])
    assert_empty self.class.violations('a.md', "badge/live%20demo-wurk.demo.#{DOMAIN}-22c55e", [])
  end

  def test_private_repository_fires_and_public_or_registry_paths_pass
    org = %w[developerz ai].join('-')

    assert_equal ['private repository'], self.class.violations('a.md', "see #{org}/vault#12", [])
    assert_equal ['private repository'], self.class.violations('a.md', "https://github.com/#{org}/vault", [])
    assert_equal ['private repository'], self.class.violations('a.md', "(#{DOMAIN} #6363)", [])
    assert_equal ['private repository'], self.class.violations('a.md', "tags, #{%w[infra structure].join}#232", [])
    assert_equal ['private repository'], self.class.violations('a.md', "(a.rb:1, #{%w[d z].join}#12)", [])
    assert_empty self.class.violations('a.md', 'adz#12, dz-12', [])
    assert_empty self.class.violations('a.md', "#{org}/wurk#12, github.com/#{org}/ultimate", [])
    assert_empty self.class.violations('a.md', "registry.example.com/#{org}/vault-demo:sha-1", [])
    assert_empty self.class.violations('a.md', 'the infrastructure (#12)', [])
  end

  def test_home_directory_and_setup_mode_fire
    home = ['', 'home', 'someone', 'src'].join('/')

    assert_equal ["someone's home directory"], self.class.violations('a.md', "cd #{home}", [])
    assert_empty self.class.violations('a.md', "cd #{['', 'home', 'runner', 'work'].join('/')}", [])
    assert_equal ['setup-mode name'], self.class.violations('a.md', "a #{%w[RUNNER DZ].reverse.join('-')} box", [])
  end

  def test_a_private_word_from_the_secret_fires
    words = self.class.private_words(" Quimtel ,\n\nzorblax.io\n")

    assert_equal 2, words.size
    assert_equal ['private word (from the secret)'], self.class.violations('lib/a.rb', '# (QUIMTEL#519)', words)
    assert_empty self.class.violations('lib/a.rb', 'zorblax-io and quim', words)
    assert_empty self.class.private_words(nil)
  end

  def test_plans_skip_only_the_private_repository_and_word_rules
    words = self.class.private_words('quimtel')
    org = %w[developerz ai].join('-')

    assert_empty self.class.violations('docs/plans/x/a.md', "quimtel, #{org}/vault", words)
    assert_equal ['internal host on our own domain'], self.class.violations('docs/plans/x/a.md', "mcp.#{DOMAIN}", words)
  end

  def test_a_required_run_without_the_secret_fails
    assert_raises(ArgumentError) { self.class.private_words_for_run(nil, required: true) }
    assert_raises(ArgumentError) { self.class.private_words_for_run(" , \n", required: true) }
    assert_empty self.class.private_words_for_run(nil, required: false)
    assert_equal 1, self.class.private_words_for_run('quimtel', required: true).size
  end
end
