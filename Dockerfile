# syntax=docker/dockerfile:1
#
# Public-demo image for wurk.demo.developerz.ai. The demo app is test/dummy/ —
# a Rails app that mounts the Wurk engine and ships the #33 workload generator.
# One image runs either the read-only dashboard (`web`) or the swarm (`worker`),
# selected by the argument to bin/demo-entrypoint.
#
# NOTE: this is the starting scaffold for the deploy (#32). The build still
# needs a verification pass with infra — see docs/demo-deploy.md.

# ---- Stage 1: build the dashboard SPA (no Node at runtime) ----
FROM node:20-bookworm-slim AS spa
WORKDIR /src
COPY frontend/package.json frontend/package-lock.json ./frontend/
RUN cd frontend && npm ci
COPY frontend/ ./frontend/
RUN cd frontend && npm run build   # → /src/vendor/assets/dashboard

# ---- Stage 2: Ruby runtime ----
FROM ruby:3.4-slim-bookworm
ENV RAILS_ENV=production \
    WURK_DEMO=1 \
    WURK_WEB_READ_ONLY=1 \
    SECRET_KEY_BASE_DUMMY=1
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential libsqlite3-dev libyaml-dev curl git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /wurk
COPY . /wurk
# Bring in the SPA bundle built in stage 1.
COPY --from=spa /src/vendor/assets/dashboard /wurk/vendor/assets/dashboard

# Install the demo app's bundle (include the puma group) and prepare its DB.
WORKDIR /wurk/test/dummy
RUN bundle config set --local without "" && \
    bundle install --jobs 4 --retry 3 && \
    SECRET_KEY_BASE=build bin/rails db:prepare

EXPOSE 3000 7433
ENTRYPOINT ["/wurk/bin/demo-entrypoint"]
CMD ["web"]
