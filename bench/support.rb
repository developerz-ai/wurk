# frozen_string_literal: true

require 'uri'

# Shared Redis DB-isolation helper for bench/*.rb. Every bench hits a dedicated
# logical DB (never DB 0) so a stray dev/CI Redis with real data can't be read,
# drained, or FLUSHDB'd by a benchmark run (#258/#259). `WURK_BENCH_DB`
# overrides the per-bench default when a caller needs to point at a specific DB.
#
# The override is rejected unless it is a positive integer: `0`, a negative, or
# a typo would otherwise silently aim a FLUSHDB at the developer's real data.
# The DB is swapped through `URI#path` rather than by string surgery so a
# query-bearing URL (`redis://host/0?timeout=1`) keeps its query instead of
# growing a `/10` suffix after it.
def bench_redis_url(default_db)
  db = ENV.fetch('WURK_BENCH_DB', default_db).to_s
  unless db.match?(/\A[1-9][0-9]*\z/)
    raise ArgumentError, "WURK_BENCH_DB must be a positive integer (DB 0 is never safe to flush), got #{db.inspect}"
  end

  uri = URI.parse(ENV['REDIS_URL'] || 'redis://localhost:6379/0')
  uri.path = "/#{db}"
  uri.to_s
end
