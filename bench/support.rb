# frozen_string_literal: true

# Shared Redis DB-isolation helper for bench/*.rb. Every bench hits a dedicated
# logical DB (never DB 0) so a stray dev/CI Redis with real data can't be read,
# drained, or FLUSHDB'd by a benchmark run (#258/#259). `WURK_BENCH_DB`
# overrides the per-bench default when a caller needs to point at a specific DB.
def bench_redis_url(default_db)
  base = ENV["REDIS_URL"] || "redis://localhost:6379/0"
  db = ENV.fetch("WURK_BENCH_DB", default_db)
  base.match?(%r{/\d+\z}) ? base.sub(%r{/\d+\z}, "/#{db}") : "#{base}/#{db}"
end
