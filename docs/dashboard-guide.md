# Dashboard guide

The dashboard is a SolidJS single-page app served by the `Wurk::Engine` Rails
engine. Securing it (auth, read-only mode, CSRF) has its own page:
[Authentication & authorization](authentication.md). Web extensions, theme
and locale settings are in [Securing the dashboard](dashboard.md).

## Mounting

```ruby
# config/routes.rb
mount Wurk::Engine => "/wurk"
```

Any path works (`/sidekiq`, `/admin/jobs`): the engine tells the SPA its mount
point on every page load, so the shipped bundle needs no rebuild.

The bundle itself (JS, CSS, fonts, icons) is served by middleware the engine
adds to the host app's stack at `/wurk-assets/`, outside the engine mount
and unauthenticated by design ([what is not gated](authentication.md#what-is-not-gated)).

### Under a sub-path

When the whole Rails app lives under a prefix — `RAILS_RELATIVE_URL_ROOT=/app`
behind a proxy that strips `/app` and sets `SCRIPT_NAME`, or a `Rack::URLMap`
— the dashboard at `/app/wurk` loads its assets from `/app/wurk-assets/`. The
shell's asset URLs carry the host's prefix, and the bundle's own chunk, font
and icon URLs are relative to it. The proxy must forward `/app/wurk-assets/`
to the app the same way it forwards `/app/wurk`.

### API-only Rails apps

An `config.api_only = true` app can mount the engine as is: it has no cookie or
session middleware, and the dashboard needs neither. Checked against such an
app: the shell, `GET /wurk/api/stats` and a same-origin `POST` all answer 200.
Session-based auth in front of it (Devise, Warden) needs the session middleware
that auth library requires, added by the host
(`config.middleware.use ActionDispatch::Cookies` and a session store).

## Content-Security-Policy

With a host policy that uses a nonce, every `<script>` in the served shell
carries the request's nonce: the pre-paint theme script, the injected mount base
and theme default, and the module entry (so `'strict-dynamic'` works too).

```ruby
# config/initializers/content_security_policy.rb
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline
    policy.connect_src :self
  end
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
```

- `connect_src :self` covers the JSON API and the live-update stream (SSE).
- A few components set static inline `style` attributes, so a `style-src`
  without `'unsafe-inline'` blocks those (layout only, nothing breaks).
- Rails' generated initializer uses `request.session.id` as the nonce; an
  API-only app has no session, so use a random nonce as above.

## Plain HTTP

Browsers send `Sec-Fetch-Site` only to HTTPS and `localhost` origins. Over
plain HTTP from another host the dashboard's mutations are checked against the
`Origin` header instead, which must match the scheme, host and port the server
sees. A mismatch — usually a proxy that rewrites `Host` — is refused with
`403 {"error":"cross_origin"}`, and the dashboard says so in a toast. Details:
[§ CSRF](authentication.md#csrf).

## Pages

| Page | Path | What it shows and does |
|---|---|---|
| Dashboard | `/` | Totals, throughput over 1h/24h/7d/30d, queue table, and a health-notices strip. `?days=N` (1..180, Sidekiq's link) opens the narrowest range covering N days; history is kept 30 days, so a longer N opens 30d. |
| Queues | `/queues`, `/queues/:name` | Depth, latency, consumers; pause, clear, delete one job. A queue's jobs list newest first, or oldest first (the next to be fetched) with the toggle or `?direction=asc`. |
| Retries, Scheduled, Dead | `/retries`, `/scheduled`, `/dead` (`/morgue`) | Paged sets with a filter over class, JID, error class, error message and args. Act on selected rows, on the whole set ("All"), or, while a filter is active, on every match across all pages ("Matching"). |
| Busy | `/busy` | Live processes and their running jobs; quiet and stop. |
| Batches | `/batches`, `/batches/:bid` | Live batches and the Dead tab (`?dead=1`, batches with a job that died), filtered by tag (`?tag=`). |
| Flows | `/flows`, `/flows/:fid` | Job DAGs; abandon a stuck flow. |
| Limiters, Cron, Metrics, Search | `/limiters`, `/cron`, `/metrics`, `/search` | Rate limiters, periodic jobs, per-class execution stats, cross-set search. |
| Profiles | `/profiles` | Captured profiles. **Open** uploads one to the public Firefox profiler with a `POST` ([profile uploads](authentication.md#profile-uploads)). |
| Extensions | `/ext/:tab` | Tabs registered by Sidekiq Web extensions. |

### Health notices

The Dashboard shows a notice for each fleet condition `wurk verify` warns
about that the dashboard can see from what it already reads (`/api/processes`
and `/api/queues`, refreshed every 30 seconds):

- a queue holds jobs, is not paused, and no live process subscribes to it;
- a live process is not Wurk (its heartbeat lacks Wurk's `cores` field, the
  test `wurk verify` uses), e.g. a real Sidekiq still on the same Redis;
- live Wurk processes run more than one version;
- processes run embedded in a web server (informational).

Nothing shows while there is nothing to report, or while no process is live.

### Acting on filter matches

With a filter active, the "All" buttons on Retries, Scheduled and Dead become
"Matching" and ask for confirmation. Each request applies the action to at
most 1,000 matches, examining at most the filter's scan budget of entries, and
answers a cursor; the page follows the cursor until the server reports the end
of the set, showing a running count. After 100 requests it stops and says more
remain.

## Bundle size

Measured on the build in this tree (`bin/rake frontend:build`), bytes as
served with `Accept-Encoding: br`:

| First load of `/` | Raw | Brotli |
|---|---|---|
| Shell (`index.html`) | 2,877 | — |
| Entry JS | 127,082 | 33,063 |
| Shared i18n chunk (preloaded) | 40,567 | 14,108 |
| Stylesheet | 141,177 | 25,206 |
| Dashboard page + charts chunks | 25,828 | 7,007 |
| Geist Sans 400–700 + JetBrains Mono 500, latin `woff2` | 160,724 | (already compressed) |

Fonts download only for the weights a page uses.
