# Wurk ⚡

**100% drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise. Free forever. Faster.** 🚀

Wire-compatible: same Redis keys, same job JSON, same Ruby DSL. Swap one gem line — existing jobs, batches, limiters, cron entries, and Redis data keep working untouched.

---

## 🏛️ The three pillars

| Pillar | What it means |
|---|---|
| 🔌 **100% drop-in** | Same Redis schema, same job JSON, same Ruby DSL. Third-party Sidekiq gems work unchanged. |
| 🆓 **Free** | Pro + Ent feature parity in the same gem. No tiers. No license check. No env-flag gates. |
| ⚡ **Faster** | Fork-based real parallelism. Every release benchmarked vs Sidekiq. >5% regression blocks merge. |

---

## ✨ What's in the box

- 🎁 **Sidekiq OSS parity** — `Sidekiq::Worker`, `Sidekiq::Job`, queues, retry/scheduled/dead sets, middleware chain, stats, heartbeat, web UI.
- 💎 **Sidekiq Pro parity** — reliable BLMOVE fetch, batches + callbacks, queue pause/resume, Redis-outage client buffer, statsd, Lua bulk path, web search.
- 🏢 **Sidekiq Enterprise parity** — rate limiters (concurrent/window/bucket), periodic jobs, leader election, unique jobs, AES-256-GCM encryption with rotation, historical metrics, multi-process swarm, rolling restarts.
- 🛠️ **Wurk extras** — worker topology DSL, mountable Rails engine, precompiled React dashboard (no Node needed by consumers), AI dashboard panes (anomaly detection, NL queries, backlog forecasting).

---

## 🚧 Status

**Skeleton stage.** Directory layout, stub classes, scripts, dummy app, CI, frontend scaffold — all wired. Implementation lands per `docs/idea/` and `docs/target/sidekiq-{free,pro,ent}.md`.

---

## 📋 Requirements

| Component | Minimum |
|---|---|
| Ruby   | `>= 3.2.0` |
| Redis  | `>= 7.0.0` (uses `ZRANGE ... REV` introduced in 6.2 and other 7.x server features) |

JRuby / TruffleRuby / Windows fall back to threads-only mode (no fork) — behaviorally equivalent to stock Sidekiq.

---

## 🏃 Quick start

```sh
bundle install
bin/rake test             # expect skipped tests until implementations land
bin/rake bench            # bench/*.rb stubs
cd test/dummy && bin/rails s
```

---

## 📁 Layout

| Path | What lives there |
|---|---|
| `lib/wurk/` | 🧩 Core — swarm, manager, fetcher, processor, client, middleware, batch, limiter, cron, … |
| `lib/wurk/engine.rb` | 🚂 Rails engine (mount point, asset path) |
| `app/` · `config/` | 🎨 Dashboard controllers + routes + locales |
| `exe/wurk` | 🏃 Standalone runner |
| `vendor/assets/dashboard/` | 📦 Precompiled SPA bundle (built at release) |
| `frontend/` | ⚛️ React + Vite source for the dashboard |
| `test/dummy/` | 🧪 Embedded Rails app for engine tests |
| `test/{unit,integration,engine}/` | ✅ Layered Minitest suites |
| `test/parity/` | 🎯 Sidekiq tests lifted as oracles (SHA-pinned) |
| `test/ecosystem/` | 🌍 Third-party Sidekiq gem suites run against Wurk |
| `bench/` | 📊 Throughput / latency / memory benchmarks |
| `docs/idea/` | 💡 Design notes |
| `docs/target/` | 📜 Sidekiq surface specs — the authoritative spec |

---

## 📜 Spec-driven

Anything implemented here MUST match `docs/target/sidekiq-{free,pro,ent}.md` exactly. Parity tests are oracles — if Wurk diverges, Wurk is wrong unless the divergence is documented.

---

## 🩺 Kubernetes probes

Opt in to a thin HTTP listener for liveness/readiness probes:

```ruby
Wurk.configure_server do |config|
  config.health_check(port: 7433)
end
```

Endpoints (off by default; only start when `health_check` is configured):

| Path     | Meaning                                                                 |
|----------|-------------------------------------------------------------------------|
| `/live`  | 200 while the Launcher is running. 503 once `stop` / `quiet` is called. |
| `/ready` | 200 only when Redis is reachable **and** the heartbeat fired within the last 30s (configurable). 503 otherwise. |

Example k8s `Deployment` spec:

```yaml
spec:
  template:
    spec:
      containers:
        - name: wurk
          image: myorg/myapp:latest
          ports:
            - containerPort: 7433
              name: health
          livenessProbe:
            httpGet:
              path: /live
              port: health
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: health
            periodSeconds: 5
            failureThreshold: 2
```

Knobs: `health_check(port:, bind: '0.0.0.0', ready_window: 30)`. In swarm mode only the first child to call `start` binds the port; the rest log a warning and skip — drive your supervisor topology accordingly.

---

## 🚀 Deployment

### Read-only dashboard

Ship a viewer-only dashboard (e.g. a public demo, or a shared read-only board) without bolting on your own auth. When read-only mode is on, every mutating request to the mounted dashboard (retry, kill, requeue, delete, pause/resume, clear) returns **403**, the SPA hides destructive actions, and a **"Read-only mode"** banner makes it unambiguous. Reads (GET) keep working.

Enable it either way:

```sh
# Simplest — works in every process, including the web server.
WURK_WEB_READ_ONLY=1
```

```ruby
# Or in a Rails initializer (config/initializers/wurk.rb):
Wurk::Web.configure { |c| c.read_only = true }
```

> The dashboard runs in your **web** process (Puma), not the worker — so set the flag there. The env var is read by every process, which is why it's the easiest option. `Wurk.configuration.web.read_only = true` reaches the same setting — `config.web` delegates to the `Wurk::Web` config singleton.

Default is read/write — nothing changes unless you opt in.

---

## 🤝 Migration

```diff
- gem "sidekiq"
- gem "sidekiq-pro",        source: "https://gems.contribsys.com/"
- gem "sidekiq-ent",        source: "https://enterprise.contribsys.com/"
+ gem "wurk"
```

Then: `bundle install && restart`. That's it. ✨

---

## 📄 License

MIT. See `LICENSE`.
