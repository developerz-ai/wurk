# frozen_string_literal: true

require 'minitest/autorun'
require 'ripper'

# `FLUSHALL` crosses every logical DB and `SCRIPT FLUSH` empties the server-wide
# EVALSHA cache, so either one, run from a test or a bench, reaches every
# parallel worker and any other suite sharing that Redis (CLAUDE.md, Never). A
# NOSCRIPT path is exercised with Wurk::Test::NoscriptFault instead.
#
# Reads code tokens, not lines, so a comment that names the commands stays legal.
class ServerWideFlushGuardTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  SKIPPED = %r{/(?:\.checkouts|vendor|node_modules)/}
  # FLUSHALL as a command string, symbol or redis-rb method; script_flush is redis-rb's.
  FLUSH_WORDS = %w[flushall script_flush].freeze

  def scanned
    files = Dir[File.join(ROOT, '{test,bench}', '**', '*.rb')] +
            Dir[File.join(ROOT, 'bin', '*')].select { |path| File.file?(path) && ruby_script?(path) }
    files.grep_v(SKIPPED) - [File.expand_path(__FILE__)]
  end

  def ruby_script?(path) = File.open(path, &:gets).to_s.match?(/\A#!.*\bruby\b/)

  def test_no_test_bench_or_bin_script_flushes_the_whole_server
    offenders = scanned.flat_map do |path|
      server_wide_flushes(File.read(path)).map { |line| "#{path.delete_prefix("#{ROOT}/")}:#{line}" }
    end

    assert_empty offenders, 'FLUSHALL / SCRIPT FLUSH reach every DB and worker on the server; ' \
                            'use FLUSHDB on your own DB, or Wurk::Test::NoscriptFault for a cold script cache'
  end

  # The scanner itself, so an empty offender list means "none", not "blind".
  def test_the_scanner_sees_each_spelling_and_ignores_comments
    {
      "c.call('SCRIPT', 'FLUSH')" => [1],
      'c.call("script", "flush", "SYNC")' => [1],
      "c.call_v(['FLUSHALL'])" => [1],
      'redis.flushall' => [1],
      'redis.script(:flush)' => [1],
      'redis.script_flush' => [1],
      "# never SCRIPT FLUSH or FLUSHALL here\nc.call('FLUSHDB')" => [],
      "c.call('SCRIPT', 'LOAD', src)" => [],
      "'redis-cli flushall'" => []
    }.each do |source, lines|
      assert_equal lines, server_wide_flushes(source), source
    end
  end

  private

  # Line numbers of every server-wide flush in `source`'s code.
  def server_wide_flushes(source)
    tokens = Ripper.lex(source).reject { |(_, type, _)| %i[on_sp on_comment on_nl on_ignored_nl].include?(type) }
    words = tokens.filter_map { |((line, _), type, tok)| [line, tok.downcase] if word?(type) }
    words.each_cons(2).filter_map { |(line, a), (_, b)| line if a == 'script' && b == 'flush' } +
      words.filter_map { |line, word| line if FLUSH_WORDS.include?(word) }
  end

  # A whole string literal, a symbol, or a method name: the shapes a command takes.
  def word?(type) = %i[on_tstring_content on_ident].include?(type)
end
