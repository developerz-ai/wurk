# frozen_string_literal: true

# Single-mode puma for the read-only demo dashboard. The producer runs in a
# thread in this process (WURK_DISABLED=1 keeps the swarm out), so keep workers
# at 0 — clustered puma would fork the producer thread away.
threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", "5"))
threads threads_count, threads_count

port Integer(ENV.fetch("PORT", "3000"))
environment ENV.fetch("RAILS_ENV", "development")
