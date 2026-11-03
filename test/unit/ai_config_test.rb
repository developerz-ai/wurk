# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'rbconfig'

# Guards the agent-facing surface: the CLAUDE.md budget, the slash commands (which
# carried another repo's stack for months, hand-fixed in #796, #799 and #819 without
# getting all of it), and the hooks. Reads files and spawns only the hook scripts;
# touches no Redis.
class AiConfigTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CLAUDE_MD = File.join(ROOT, 'CLAUDE.md')
  # developerz.ai's in-cluster loader keeps this many chars of the root brain
  # (HOUSE_BRAIN_FLOOR_CHARS). Past it the rules are invisible to triage. Move text
  # into a nested CLAUDE.md; never raise this.
  BRAIN_FLOOR_CHARS = 12_000
  LOAD_BEARING_HEADINGS = ['## Wurk', '## Never', '## Conventions', '## Testing'].freeze
  # Stack words from the monorepo these commands were copied from.
  FOREIGN = %r{@developerz/|packages/ui|apps/\*|packages/\*|GHCR|Drizzle|\bZod\b|\bBiome\b|\bHono\b|BullMQ|audit rows}
  COMMANDS = Dir[File.join(ROOT, '.claude/commands/*.md')].freeze
  GUARD = File.join(ROOT, '.claude/hooks/guard_bash.rb')
  POST_EDIT = File.join(ROOT, '.claude/hooks/post_edit.rb')

  REFUSED = [
    'git push --force origin main',
    'git push -f origin main',
    'git push origin +main',
    'FOO=1 git push --force-with-lease origin HEAD:main',
    'git -C . commit --no-verify -m x',
    'git commit -nm x',
    'git worktree add ../x',
    'git tag v1.2.3',
    'git push origin v1.2.3',
    'git push --tags',
    'gem push pkg/wurk-1.0.0.gem',
    'bin/gem-push',
    'gh pr merge 12 --admin --squash',
    'redis-cli flushall',
    'redis-cli FLUSHDB',
    'redis-cli -p 6379 flushall',
    'redis-cli -u redis://localhost:6379/0 flushall',
    'pkill -f wurkswarm',
    "pkill -f 'bench/fetch'",
    'WURK_HOOKS_OFF=1 git tag v9.9.9',
    'cd /tmp && git tag v9',
    'redis-cli -n 0 flushdb',
    'redis-cli -n 0 FLUSHDB',
    'redis-cli -h 127.0.0.1 -p 6379 -n 0 flushdb',
    'redis-cli -h 127.0.0.1 flushdb',
    'redis-cli -u redis://localhost:6379/0 flushdb',
    'redis-cli -u redis://localhost/0 flushdb',
    'redis-cli -u redis://localhost:6379 flushdb',
    'redis-cli -u "redis://localhost:6379/0" flushdb',
    'redis-cli -n 3 flushall',
    'redis-cli script flush',
    'git push -fu origin main',
    'git push -uf origin main',
    "git push origin 'main' --force",
    'git push origin "main" -f',
    'git push origin +HEAD:main',
    'git push origin HEAD:refs/heads/main --force',
    'git push --force-with-lease=main:abc origin main',
    'git commit --no-verify -uno',
    'git commit -n',
    'git commit -an',
    'git push origin v1.2.3-rc1',
    'git push origin refs/tags/anything',
    'git push origin HEAD:v1.2.3'
  ].freeze

  ALLOWED = [
    'git push origin feature/x',
    'git push --force-with-lease origin feature/x',
    'git commit -m "explain why git tag v1 and --no-verify are refused"',
    "git commit -m 'gem push && git tag v1'",
    'git tag',
    'git tag --list',
    'git tag -l "v*"',
    'git worktree list',
    'git log --oneline -n 5',
    'gh pr merge 12 --squash',
    'redis-cli -n 3 flushdb',
    'redis-cli -u redis://localhost:6379/3 flushdb',
    'redis-cli -p 16399 flushall',
    'git push origin v2-rewrite',
    "pkill -f '[w]urkswarm'",
    'pkill puma',
    'gem list',
    'git commit -uno',
    'git commit -mn',
    'git commit -am "x"',
    'git push origin v1.2.3-fix',
    'git push -u origin feature/x',
    'git push -fu origin feature/x',
    "git push origin 'feature/main' --force",
    'redis-cli -p 16399 -n 0 flushdb',
    'redis-cli -u redis://localhost:16399/0 flushdb',
    'redis-cli -u "redis://localhost:6379/3" flushdb',
    'redis-cli -n 3 get flushdb',
    "cat <<'EOF'\ngit tag v1\nEOF"
  ].freeze

  def test_root_brain_fits_the_floor
    size = File.read(CLAUDE_MD).strip.length

    assert_operator size, :<=, BRAIN_FLOOR_CHARS, "CLAUDE.md is #{size} chars; move detail to a nested CLAUDE.md"
  end

  def test_agents_md_is_the_same_file
    assert_equal 'CLAUDE.md', File.readlink(File.join(ROOT, 'AGENTS.md'))
  end

  def test_nested_brains_the_root_points_at_exist
    File.read(CLAUDE_MD).scan(%r{\]\(([\w./-]+CLAUDE\.md)\)}).flatten.each do |path|
      assert File.file?(File.join(ROOT, path)), "CLAUDE.md links #{path}, which does not exist"
    end
  end

  def test_load_bearing_sections_exist
    text = File.read(CLAUDE_MD)

    LOAD_BEARING_HEADINGS.each { |heading| assert_includes text, "\n#{heading}", "CLAUDE.md lost #{heading}" }
  end

  def test_commands_carry_no_foreign_stack
    refute_empty COMMANDS
    COMMANDS.each do |path|
      hits = File.read(path).scan(FOREIGN)

      assert_empty hits, "#{File.basename(path)} names another repo's stack: #{hits.uniq.join(', ')}"
    end
  end

  def test_commands_have_description_frontmatter
    COMMANDS.each do |path|
      assert_match(/\A---\n(?:.*\n)*?description: \S.*\n(?:.*\n)*?---\n/, File.read(path), File.basename(path))
    end
  end

  def test_repo_paths_the_commands_name_exist
    COMMANDS.each do |path|
      named = File.read(path).scan(%r{`((?:lib|bin|exe|docs|test|frontend|app|\.github)/[\w./-]+)`}).flatten
      missing = named.reject { |rel| rel.match?(/[<*{]/) || File.exist?(File.join(ROOT, rel)) }

      assert_empty missing, "#{File.basename(path)} names missing paths: #{missing.uniq.join(', ')}"
    end
  end

  def test_settings_point_at_hooks_that_exist
    commands = JSON.parse(File.read(File.join(ROOT, '.claude/settings.json'))).fetch('hooks').values.flatten
                   .flat_map { |entry| entry.fetch('hooks') }.map { |hook| hook.fetch('command') }

    refute_empty commands
    commands.flat_map { |command| command.scan(%r{\.claude/hooks/[\w.]+}) }.each do |rel|
      assert File.file?(File.join(ROOT, rel)), "settings.json runs #{rel}, which does not exist"
    end
  end

  def test_guard_refuses_what_claude_md_forbids
    REFUSED.each { |command| assert_equal 2, guard(command), "must refuse: #{command}" }
  end

  def test_guard_allows_ordinary_work
    ALLOWED.each { |command| assert_equal 0, guard(command), "must allow: #{command}" }
  end

  def test_session_env_turns_the_guard_off
    payload = JSON.generate(tool_input: { command: 'git tag v9.9.9' })
    _out, status = Open3.capture2e({ 'WURK_HOOKS_OFF' => '1' }, RbConfig.ruby, GUARD, stdin_data: payload)

    assert_equal 0, status.exitstatus
  end

  def test_post_edit_advises_and_never_blocks_on_non_ruby
    assert_match(/oracles/, post_edit('test/parity/README.md').first)
    assert_equal ['', 0], post_edit('README.md')
    assert_equal ['', 0], post_edit('/etc/hostname')
  end

  def test_guard_fails_open_on_garbage
    assert_equal 0, run_guard('not json')
  end

  private

  def post_edit(path)
    payload = JSON.generate(tool_input: { file_path: path })
    out, status = Open3.capture2e({ 'COVERAGE' => nil, 'WURK_HOOKS_OFF' => nil }, RbConfig.ruby, '--disable-gems',
                                  POST_EDIT, stdin_data: payload, chdir: ROOT)
    [out, status.exitstatus]
  end

  def guard(command)
    run_guard(JSON.generate(tool_input: { command: command }))
  end

  def run_guard(stdin)
    _out, status = Open3.capture2e({ 'COVERAGE' => nil }, RbConfig.ruby, '--disable-gems', GUARD, stdin_data: stdin)
    status.exitstatus
  end
end
