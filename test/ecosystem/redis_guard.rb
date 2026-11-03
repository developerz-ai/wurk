# frozen_string_literal: true

require 'uri'

# The third-party suites flush whatever Redis DB they connect to, before and after
# every example. This is what stands between them and data that isn't theirs. Nothing
# here needs a gem, so bin/test-ecosystem can run it before any bundle exists.
module EcosystemRedisGuard
  HARNESS_DB = 15
  DEFAULT_PORT = 6379
  LOOPBACK = %w[localhost 127.0.0.1 ::1 [::1]].freeze
  SCANNED_DIRS = %w[spec test].freeze
  REDIS_URL = %r{rediss?://[^\s"'`)\]]+}
  DEFAULT_PORT_LITERAL = /\bport:\s*#{DEFAULT_PORT}\b/

  class Unsafe < StandardError; end

  module_function

  # @raise [Unsafe] unless `url` names the harness DB, and only that, on a server that
  #   isn't the well-known local one. A DB the URL leaves implicit is DB 0.
  def check_url!(url)
    uri = parse(url)
    raise Unsafe, "#{url}: need redis:// or rediss://, got #{uri.scheme.inspect}" unless %w[redis
                                                                                            rediss].include?(uri.scheme)

    dbs = [uri.path.delete_prefix('/'), *query_dbs(uri)]
    raise Unsafe, "#{url}: DB must be #{HARNESS_DB}, the harness's own" unless dbs.uniq == [HARNESS_DB.to_s]
    return url unless LOOPBACK.include?(uri.host) && (uri.port || DEFAULT_PORT) == DEFAULT_PORT

    raise Unsafe, "#{url}: the local default Redis is shared. Leave ECOSYSTEM_REDIS_URL unset for a throwaway server"
  end

  # What's still in a prepared checkout that would reach DB 0 or the default port.
  # A DB chosen at runtime (`/#{db}`) can't be proven safe, so it counts.
  def unsafe_literals(checkout, allowed = [])
    checkout = File.expand_path(checkout)
    SCANNED_DIRS.flat_map { |dir| Dir[File.join(checkout, dir, '**', '*.{rb,yml}')] }.flat_map do |file|
      relative = file.delete_prefix("#{checkout}/")
      File.foreach(file).with_index(1).filter_map do |line, number|
        next unless unsafe_line?(line) && allowed.none? { |path| relative == path }

        "#{relative}:#{number}: #{line.strip}"
      end
    end
  end

  def unsafe_line?(line)
    line.match?(DEFAULT_PORT_LITERAL) || line.scan(REDIS_URL).any? { |url| url_reaches_db_zero?(url) }
  end

  def url_reaches_db_zero?(url)
    return true if url.include?('#{')

    uri = parse(url)
    db = query_dbs(uri).first || uri.path.delete_prefix('/')
    db.empty? || db.to_i.zero?
  rescue Unsafe
    true
  end

  # The connection's own word, for the last step before a FLUSHDB. `client_info` is
  # what CLIENT INFO answered.
  def check_connection!(client_info)
    db = client_info[/\bdb=(\d+)/, 1]
    return if db == HARNESS_DB.to_s

    raise Unsafe,
          "refusing FLUSHDB on DB #{db.inspect}: not the harness's DB #{HARNESS_DB}"
  end

  def parse(url)
    URI.parse(url)
  rescue URI::InvalidURIError
    raise Unsafe, "#{url}: not a URL"
  end

  def query_dbs(uri) = URI.decode_www_form(uri.query.to_s).filter_map { |key, value| value if key == 'db' }
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  begin
    case ARGV.shift
    when 'url' then EcosystemRedisGuard.check_url!(ARGV.fetch(0))
    when 'scan'
      allow_file = ARGV[1].to_s
      listed = File.file?(allow_file) ? File.readlines(allow_file, chomp: true) : []
      allowed = listed.reject { |line| line.empty? || line.start_with?('#') }
      found = EcosystemRedisGuard.unsafe_literals(ARGV.fetch(0), allowed)
      unless found.empty?
        raise EcosystemRedisGuard::Unsafe, "still reaches DB 0 or the default port:\n#{found.join("\n")}"
      end
    else abort 'usage: redis_guard.rb url <url> | scan <checkout> [allow-file]'
    end
  rescue EcosystemRedisGuard::Unsafe => e
    abort "bin/test-ecosystem: #{e.message}"
  end
end
