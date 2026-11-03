# frozen_string_literal: true

# PreToolUse hook on Bash: refuses the commands CLAUDE.md forbids and the release
# moves that made seven gem-less GitHub Releases (RELEASE.md, wurk#420).
#
#   refused        → exit 2, reason on stderr (Claude Code feeds it back to the agent)
#   anything else  → exit 0, silent
#
# Fails open on anything it cannot parse: this is a seatbelt for honest mistakes, not
# a sandbox, and a broken hook must never wedge a session. Text inside quotes and
# heredocs is removed first, so a commit message that says "git tag" is not a tag. A
# quoted single word stays, so `git push origin 'main'` still names main.
# WURK_HOOKS_OFF=1 in the session's environment turns it off (.claude/README.md); as
# a prefix on the refused command it does nothing, because that never reaches this
# process.
# Pinned by test/unit/ai_config_test.rb.
require 'json'

module GuardBash
  WRAPPERS = %w[sudo command exec env time nice].freeze
  GIT_VALUE_OPTIONS = %w[-C -c --git-dir --work-tree].freeze
  TAG_READ_ONLY = /\A(?:-l|--list|-n\d*|--(?:no-)?contains|--(?:no-)?merged|--points-at|--sort|--format|-d|--delete)/
  PROTECTED_BRANCH = %r{\A\+?(?:refs/heads/)?main\z}
  # `-o` takes a value, so an `f` after it is the value's.
  FORCE_FLAG = /\A(?:-[a-np-zA-Z]*f|--force|--force-with-lease|--force-if-includes)/
  # Prereleases are the only suffix a release tag has (ReleaseHelpers.git_tag_for).
  TAG_REFSPEC = %r{\A\+?(?:refs/tags/|v\d+\.\d+\.\d+(?:-(?:rc|alpha|beta|pre)[.\d]*)?\z)}
  # `-u`, `-m` and friends take an attached value: the `n` in `-uno` is not --no-verify's.
  COMMIT_NO_VERIFY = /\A-[^mFCctSu-]*n/
  QUOTED_WORD = %r{(["'])(?!-)([\w./:+@-]*)\1}
  REDIS_VALUE_OPTIONS = %w[-h -p -n -u -a -s].freeze
  REDIS_URL = %r{://(?:[^/@]*@)?[^/:]*(?::(?<port>\d+))?(?:/(?<db>\d+))?}
  SHARED_PORT = '6379'
  PKILL_SAFE_PATTERN = /-\w*f\w*\s+['"]?\S*\[/

  module_function

  def refusal(command)
    segments(command).each do |tokens|
      reason = check(tokens, command)
      return reason if reason
    end
    nil
  end

  def segments(command)
    text = command.gsub(/<<-?\s*['"]?(\w+)['"]?.*?^\s*\1\s*$/m, ' ')
    text = text.gsub(QUOTED_WORD, '\2')
    text = text.gsub(/"(?:\\.|[^"\\])*"/, '""').gsub(/'[^']*'/, "''")
    text.split(/&&|\|\||[;|\n]/).map { |part| strip_prefix(part.split) }.reject(&:empty?)
  end

  def strip_prefix(tokens)
    tokens = tokens.drop(1) while tokens.first&.match?(/\A\w+=/) || WRAPPERS.include?(tokens.first)
    tokens
  end

  def check(tokens, command)
    case File.basename(tokens.first.to_s)
    when 'pkill' then check_pkill(tokens, command)
    when 'git' then check_git(tokens.drop(1))
    when 'gem' then 'gem push is CI-only: merge a lib/wurk/version.rb bump (RELEASE.md).' if tokens[1] == 'push'
    when 'gem-push' then 'bin/gem-push is break-glass for a human: merge a lib/wurk/version.rb bump (RELEASE.md).'
    when 'gh' then check_gh(tokens)
    when 'redis-cli' then check_redis(tokens)
    end
  end

  def check_git(args)
    args = drop_git_options(args)
    case args.first
    when 'push' then check_push(args.drop(1))
    when 'commit' then check_commit(args.drop(1))
    when 'worktree' then 'No git worktrees (CLAUDE.md): split agents by file set.' if args[1] == 'add'
    when 'tag' then check_tag(args.drop(1))
    end
  end

  def drop_git_options(args)
    args = args.drop(GIT_VALUE_OPTIONS.include?(args.first) ? 2 : 1) while args.first&.start_with?('-')
    args
  end

  def check_commit(args)
    return unless args.include?('--no-verify') || args.any? { |arg| arg.match?(COMMIT_NO_VERIFY) }

    '--no-verify is forbidden (CLAUDE.md): fix the hook.'
  end

  def check_push(args)
    return '--no-verify is forbidden (CLAUDE.md): fix the hook.' if args.include?('--no-verify')
    return 'The release tag is an output of release.yml, never pushed by hand (RELEASE.md, wurk#420).' if tags?(args)

    'Force-push to main is forbidden (CLAUDE.md).' if forced?(args) && targets_main?(args)
  end

  def tags?(args)
    return true if args.include?('--tags') || args.include?('--follow-tags')

    args.any? { |arg| !arg.start_with?('-') && arg.split(':').last.to_s.match?(TAG_REFSPEC) }
  end

  def forced?(args)
    args.any? { |arg| arg.match?(FORCE_FLAG) || arg.start_with?('+') }
  end

  def targets_main?(args)
    refspecs = args.reject { |arg| arg.start_with?('-') }.drop(1)
    return current_branch == 'main' if refspecs.empty? || refspecs.any? { |ref| ref.delete_prefix('+') == 'HEAD' }

    refspecs.any? { |ref| ref.split(':').last.match?(PROTECTED_BRANCH) }
  end

  def current_branch
    `git symbolic-ref --short -q HEAD 2>/dev/null`.strip
  end

  def check_tag(args)
    return if args.empty? || args.any? { |arg| arg.match?(TAG_READ_ONLY) }

    'The release tag is an output of release.yml, never created by hand (RELEASE.md, wurk#420).'
  end

  def check_gh(tokens)
    return unless tokens[1] == 'pr' && tokens[2] == 'merge' && tokens.include?('--admin')

    '--admin bypasses the main-protection ruleset: get the required checks green.'
  end

  def check_pkill(tokens, command)
    return unless tokens.any? { |arg| arg.match?(/\A-\w*f\w*\z/) } && !command.match?(PKILL_SAFE_PATTERN)

    'pkill -f matches this very shell, whose command line holds the pattern: use a [b]racket pattern, or kill by pid.'
  end

  # A private throwaway server is its owner's to flush; the shared one is not.
  def check_redis(tokens)
    options, words = redis_args(tokens.drop(1))
    command = words.first(2).map(&:downcase)
    return unless %w[flushall flushdb].include?(command.first) || command == %w[script flush]

    port, db = redis_target(options)
    return unless port == SHARED_PORT
    return 'redis-cli FLUSHALL and SCRIPT FLUSH cross every DB: use FLUSHDB -n <db>.' if command.first != 'flushdb'

    'redis-cli FLUSHDB on DB 0 hits real data, never the test DBs: pass -n <db> with a test DB.' if db.to_i.zero?
  end

  def redis_args(args)
    options = {}
    words = []
    until args.empty?
      arg, *args = args
      if REDIS_VALUE_OPTIONS.include?(arg)
        options[arg] = args.shift
      elsif !arg.start_with?('-')
        words << arg
      end
    end
    [options, words]
  end

  def redis_target(options)
    url = options['-u'].to_s.match(REDIS_URL)
    [options['-p'] || url&.[](:port) || SHARED_PORT, options['-n'] || url&.[](:db)]
  end
end

if $PROGRAM_NAME == __FILE__
  exit 0 if ENV['WURK_HOOKS_OFF'] == '1'

  begin
    command = JSON.parse($stdin.read).dig('tool_input', 'command')
    reason = GuardBash.refusal(command) if command.is_a?(String)
  rescue StandardError
    reason = nil
  end
  if reason
    warn "Refused by .claude/hooks/guard_bash.rb: #{reason}"
    exit 2
  end
end
