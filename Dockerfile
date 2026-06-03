# syntax=docker/dockerfile:1
#
# Public-demo image for wurk.demo.developerz.ai. The demo app is demo/ — a
# Rails 8 app that mounts the Wurk dashboard read-only and runs a producer that
# exercises cron, unique, batch, rate-limited, and failing jobs. One image runs
# either the read-only dashboard (`web`) or the swarm (`worker`), selected by the
# argument to bin/demo-entrypoint.
#
# NOTE: this is the starting scaffold for the deploy (#32). The build still
# needs a verification pass with infra — see docs/demo-deploy.md.

# ---- Stage 1: build the dashboard SPA (no Node at runtime) ----
FROM node:20-bookworm-slim AS spa
WORKDIR /src
COPY frontend/package.json frontend/package-lock.json ./frontend/
RUN cd frontend && npm ci
COPY frontend/ ./frontend/
# vite.config.ts's wurk-manifest-generator plugin readFileSync's ../lib/wurk/version.rb
# at build time, so the SPA stage needs it present (was missing → npm run build ENOENT).
COPY lib/wurk/version.rb ./lib/wurk/version.rb
RUN cd frontend && npm run build   # → /src/vendor/assets/dashboard

# ---- Stage 2: Ruby runtime ----
FROM ruby:3.4-slim-bookworm
# RAILS_ENV=production; the runtime must supply a real SECRET_KEY_BASE (k8s
# secret — see docs/demo-deploy.md). Read-only + demo mode are baked in.
ENV RAILS_ENV=production \
    WURK_DEMO=1 \
    WURK_WEB_READ_ONLY=1
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential libsqlite3-dev libyaml-dev curl git && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --create-home --shell /bin/bash wurk

WORKDIR /wurk
COPY . /wurk
# Bring in the SPA bundle built in stage 1.
COPY --from=spa /src/vendor/assets/dashboard /wurk/vendor/assets/dashboard

# Install the demo app's bundle, prepare its DB, then hand the tree to the
# non-root runtime user.
WORKDIR /wurk/demo
RUN bundle install --jobs 4 --retry 3 && \
    SECRET_KEY_BASE=build bin/rails db:prepare && \
    chown -R wurk:wurk /wurk

USER wurk
EXPOSE 3000 7433
ENTRYPOINT ["/wurk/bin/demo-entrypoint"]
CMD ["web"]
