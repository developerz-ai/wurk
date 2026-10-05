# frozen_string_literal: true

require_relative '../test_helper'

# Every key a Lua script touches must arrive through KEYS. Redis Cluster routes
# a script by its declared keys and refuses an undeclared one, and Dragonfly
# refuses undeclared-key access outright (#91: the bucket limiter built its
# epoch key inside Lua and broke on both). A script that concatenates a key
# name from a prefix works on a single stock Redis and nowhere else, so nothing
# but a scan catches it before a user on one of those does.
#
# Static, deliberately simple: for each `redis.call` / `redis.pcall`, the key
# argument(s) must be `KEYS[...]`, `unpack(KEYS, ...)`, or a name bound only
# from such an expression — a `local` assigned from `KEYS[...]`, or a function
# parameter every call site passes one to. Anything else is flagged.
class LuaDeclaredKeysTest < Wurk::Test::UnitCase
  parallelize_me!

  # Commands whose key is not the first argument, or that take several.
  KEY_POSITIONS = {
    'TIME' => [],
    'LMOVE' => [0, 1], 'BLMOVE' => [0, 1], 'RPOPLPUSH' => [0, 1], 'SMOVE' => [0, 1],
    'RENAME' => [0, 1], 'COPY' => [0, 1]
  }.freeze
  VARIADIC = %w[DEL UNLINK EXISTS TOUCH MGET].freeze

  # Script => why it still builds a key in Lua. Only with a reason that names
  # who has to change what; an entry here is a known Cluster/Dragonfly break.
  ALLOWED = {}.freeze

  def test_every_lua_file_touches_only_declared_keys
    offenders = Dir[File.join(Wurk::Lua::LUA_DIR, '*.lua')].flat_map do |path|
      name = File.basename(path, '.lua').to_sym
      next [] if ALLOWED.key?(name)

      undeclared_keys(File.read(path)).map { |call| "#{File.basename(path)}: #{call}" }
    end

    assert_empty offenders, "redis.call with a key not passed via KEYS:\n#{offenders.join("\n")}"
  end

  def test_every_allowlisted_script_still_needs_its_entry
    stale = ALLOWED.keys.reject do |name|
      undeclared_keys(File.read(File.join(Wurk::Lua::LUA_DIR, "#{name}.lua"))).any?
    end

    assert_empty stale, "allowlisted but clean now — drop the entry: #{stale.inspect}"
  end

  def test_the_scanner_flags_a_key_built_inside_lua
    src = <<~LUA
      local prefix = KEYS[1]
      local key = prefix .. ':' .. ARGV[1]
      redis.call('SET', key, 1)
      redis.call('GET', 'queue:' .. ARGV[2])
    LUA

    assert_equal 2, undeclared_keys(src).size
  end

  def test_the_scanner_follows_keys_through_locals_and_parameters
    src = <<~LUA
      local a, b = KEYS[1], KEYS[2]
      local function touch(k, v) redis.call('SET', k, v) end
      touch(KEYS[3], ARGV[1])
      redis.call('LMOVE', a, b, 'RIGHT', 'LEFT')
      redis.call('UNLINK', unpack(KEYS, 4, #KEYS))
      local t = redis.call('TIME')
    LUA

    assert_empty undeclared_keys(src)
  end

  private

  def undeclared_keys(source)
    src = strip_comments(source)
    key_names = bound_key_names(src)
    redis_calls(src).filter_map do |args|
      command = args.first.to_s.delete("'\"").upcase
      key_args(command, args.drop(1)).reject { |arg| declared?(arg, key_names) }.then do |bad|
        "redis.call(#{args.join(', ')})" unless bad.empty?
      end
    end
  end

  def key_args(command, rest)
    return rest if VARIADIC.include?(command)

    KEY_POSITIONS.fetch(command, [0]).filter_map { |i| rest[i] }
  end

  def declared?(arg, key_names)
    arg.match?(/\AKEYS\[[^\]]+\]\z/) || arg.start_with?('unpack(KEYS') || key_names.include?(arg)
  end

  # `local x = KEYS[n]` / `local a, b = KEYS[1], KEYS[2]`, then, to a fixpoint,
  # function parameters that every call site fills with a key expression.
  def bound_key_names(src)
    names = Set.new
    src.scan(/local[ \t]+([\w \t,]+?)[ \t]*=[ \t]*(?:\n[ \t]*)?([^\n]+)/) do |lhs, rhs|
      lhs.split(',').map(&:strip).zip(split_top_level(rhs.strip)).each do |name, expr|
        names << name if expr&.match?(/\AKEYS\[[^\]]+\]\z/)
      end
    end
    loop do
      added = function_key_params(src, names) - names.to_a
      break if added.empty?

      names.merge(added)
    end
    names
  end

  def function_key_params(src, names)
    src.scan(/function\s+(\w+)\s*\(([^)]*)\)/).flat_map do |fname, params|
      params = params.split(',').map(&:strip)
      calls = call_args(src, fname)
      next [] if calls.empty?

      params.each_with_index.filter_map do |param, i|
        param if calls.all? { |args| args[i] && declared?(args[i], names) }
      end
    end
  end

  def redis_calls(src)
    call_args(src, 'redis.call') + call_args(src, 'redis.pcall')
  end

  # Argument lists of every `name(` call that is not the function's own
  # definition, split on top-level commas.
  def call_args(src, name)
    out = []
    src.to_enum(:scan, /(?<![\w.])#{Regexp.escape(name)}\s*\(/).each do
      start = Regexp.last_match.end(0)
      next if src[0...Regexp.last_match.begin(0)].match?(/function\s+\z/)

      out << split_top_level(balanced(src, start))
    end
    out
  end

  def balanced(src, start)
    depth = 1
    i = start
    quote = nil
    while i < src.size
      c = src[i]
      if quote
        quote = nil if c == quote
      elsif ["'", '"'].include?(c)
        quote = c
      elsif '([{'.include?(c)
        depth += 1
      elsif ')]}'.include?(c)
        depth -= 1
        return src[start...i] if depth.zero?
      end
      i += 1
    end
    src[start..]
  end

  def split_top_level(str)
    parts = []
    depth = 0
    quote = nil
    current = +''
    str.each_char do |c|
      if quote
        quote = nil if c == quote
      elsif ["'", '"'].include?(c)
        quote = c
      elsif '([{'.include?(c)
        depth += 1
      elsif ')]}'.include?(c)
        depth -= 1
      elsif c == ',' && depth.zero?
        parts << current.strip
        current = +''
        next
      end
      current << c
    end
    parts << current.strip unless current.strip.empty?
    parts
  end

  # `--` to end of line, outside a string literal.
  def strip_comments(source)
    source.each_line.map do |line|
      quote = nil
      cut = line.size
      line.each_char.with_index do |c, i|
        if quote
          quote = nil if c == quote
        elsif ["'", '"'].include?(c)
          quote = c
        elsif c == '-' && line[i + 1] == '-'
          cut = i
          break
        end
      end
      line[0...cut].rstrip
    end.join("\n")
  end
end
