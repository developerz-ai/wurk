# frozen_string_literal: true

# PostToolUse hook on Edit|Write|MultiEdit: the mistakes the fix-after-fix history repeats,
# caught at the edit instead of at bin/check or in review.
#
#   rubocop offenses in the edited .rb → exit 2, offenses on stderr
#   everything else                    → exit 0, advice as additionalContext
#
# Check-only: an autocorrect would rewrite the file under the agent and fail its next
# Edit. A missing tool or a timeout is the environment, never the agent's fault, so it
# only ever says so. Pinned by test/unit/ai_config_test.rb.
require 'json'
require 'open3'

module PostEdit
  RUBOCOP_SECONDS = '12'
  ANCHOR_GLOB = 'test/conformance/ledger_anchors/*.yml'
  WIRE_FILES = %w[lib/wurk/keys.rb lib/wurk/job_util.rb].freeze
  # `bundle exec` exits 1 with this in a stack trace when the lockfile's gems are
  # not installed: the edit went unlinted, and it is not a rubocop offense.
  GEMS_MISSING = 'Bundler::GemNotFound'

  module_function

  def relative(file, root)
    absolute = File.expand_path(file, root)
    absolute.delete_prefix("#{root}/") if absolute.start_with?("#{root}/") && File.file?(absolute)
  end

  def rubocop_failure(path)
    return unless path.end_with?('.rb')

    out, status = run('timeout', RUBOCOP_SECONDS, 'bundle', 'exec', 'rubocop', '--force-exclusion',
                      '--format', 'emacs', path)
    @gems_missing = out.to_s.include?(GEMS_MISSING)
    out if status&.exitstatus == 1 && !@gems_missing
  end

  def bundle_note
    'Gems are missing, so rubocop did not lint this edit: run `bundle install` (or `bin/setup`).' if @gems_missing
  end

  def advice(path, root)
    notes = [bundle_note, anchor_note(path, root), parity_note(path), wire_note(path), version_note(path)]
    notes << lint_note(path)
    notes.compact
  end

  def anchor_note(path, root)
    return unless path.start_with?('lib/')

    count = Dir[File.join(root, ANCHOR_GLOB)].sum { |file| File.read(file).scan("anchor: #{path}#").size }
    return if count.zero?

    "#{count} ledger anchors pin line ranges in #{path}. If lines moved, run `bin/repin-anchors` on the tree " \
      'the PR will contain, then `bin/rake test:parity`; `bin/check` reports drift but does not fix it.'
  end

  def parity_note(path)
    return unless path.start_with?('test/parity/')

    'Parity tests are oracles: when Wurk diverges, Wurk is wrong unless docs/idea/parity-divergences.md ' \
      'records it as intentional. Do not weaken an assertion to get green.'
  end

  def wire_note(path)
    return unless WIRE_FILES.include?(path) || path.start_with?('lib/wurk/lua/')

    'Wire-compat surface: a Redis key, job JSON field or sorted-set score format must not change.'
  end

  def version_note(path)
    return unless path == 'lib/wurk/version.rb'

    'A merged bump IS the release: `bundle exec rake release:relock_demo`, move [Unreleased] in CHANGELOG, ' \
      'one `release: x.y.z` PR with nothing else, never tag (RELEASE.md).'
  end

  def lint_note(path)
    if path.start_with?('.github/workflows/') then tool_note('actionlint', path)
    elsif path.start_with?('bin/') && File.extname(path).empty? && shell_script?(path)
      tool_note('shellcheck', '-S', 'warning', path)
    end
  end

  def shell_script?(path)
    File.open(path, &:gets).to_s.match?(/\A#!.*\b(?:ba)?sh\b/)
  end

  def tool_note(tool, *args)
    out, status = run(tool, *args)
    return "#{tool} is not on PATH, so #{args.last} was not linted; CI will." if status.nil?

    "#{tool} on #{args.last}:\n#{out.lines.first(40).join}" unless status.success?
  end

  def run(*command)
    out, err, status = Open3.capture3(*command)
    [out + err, status]
  rescue SystemCallError
    [nil, nil]
  end
end

if $PROGRAM_NAME == __FILE__
  exit 0 if ENV['WURK_HOOKS_OFF'] == '1'

  begin
    file = JSON.parse($stdin.read).dig('tool_input', 'file_path')
    root = File.realpath(Dir.pwd)
    path = PostEdit.relative(file, root) if file.is_a?(String)
    exit 0 unless path

    if (offenses = PostEdit.rubocop_failure(path))
      warn offenses.lines.first(40).join
      exit 2
    end
    notes = PostEdit.advice(path, root)
    unless notes.empty?
      puts JSON.generate(hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: notes.join("\n") })
    end
  rescue StandardError => e
    warn "post_edit hook: #{e.class}: #{e.message}"
  end
end
