# Authentication & authorization

The Wurk dashboard is a mountable Rails engine with **no session layer of its
own**. It never authenticates anyone — it reads the identity your app already
established and decides whether that request may proceed. Gating it is the
first thing every production deploy does.

> **Warning: host controller filters do not protect the dashboard.**
> `Wurk::ApplicationController` inherits from `ActionController::Base`, not your
> host application's `ApplicationController`. The dashboard controllers therefore
> do not inherit host filters: a `before_action :authenticate_user!` in your
> `ApplicationController` does **not** protect a bare `mount Wurk::Engine`.
>
> Controller callbacks are separate from Rack middleware: the host's middleware
> still runs, and an existing session or Warden identity can be available, but
> that alone does not enforce dashboard access. Explicitly gate the mount with
> [route-level `authenticate` or `constraints`](#1-route-level-gate-the-mount),
> [`Wurk::Web.use` middleware](#2-wurkwebuse--rack-middleware), or
> [`config.authorization`](#3-authorization--per-request-method--and-path-aware)
> using the existing identity. Read-only mode and CSRF checks are not
> authentication.

There are four independent controls, applied in this order:

| # | Control | Answers | Where |
|---|---------|---------|-------|
| 1 | Route-level gate (`authenticate`, `constraints`) | May this request reach the engine at all? | `config/routes.rb` |
| 2 | `Wurk::Web.use` | Rack middleware wrapping the dashboard (Devise/Warden, Sorcery, Basic auth, custom) | `config/initializers/wurk.rb` |
| 3 | `config.authorization` | Per-request `(env, method, path)` check — role gating GET vs POST | `config/initializers/wurk.rb` |
| 4 | `config.read_only` | Blanket "nobody mutates anything" | Ruby or `WURK_WEB_READ_ONLY=1` |

They compose; you can use one, or all four. On top of them Wurk enforces a
same-origin CSRF check on every mutating request (see [§ CSRF](#csrf)).

Everything here is Sidekiq-compatible: `Sidekiq::Web.use(...)` and
`Sidekiq::Web.configure { … }` are aliases, so an existing Sidekiq initializer
keeps working on the one-line gem swap.

> **Scope.** These hooks affect only requests routed **under the engine
> mount** (or a [standalone `Sidekiq::Web` mount](#the-standalone-sidekiqweb-mount)).
> Your app's own controllers are untouched.

---

## 1. Route-level: gate the mount

The simplest gate, and the one most apps want: don't route the request to the
engine unless the user is already signed in.

### Devise

Devise ships `authenticate`, which wraps a routes block in a Warden check.
Unauthenticated visitors are bounced to your login page (Devise's failure app),
and signed-in non-admins get a 401 rather than a dashboard:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  devise_for :users

  authenticate :user, ->(u) { u.admin? } do
    mount Wurk::Engine => "/wurk"
  end
end
```

- `:user` is the Devise **scope** — use the scope you actually gate on
  (`:admin_user`, `:staff`, …).
- The lambda is optional. `authenticate :user do … end` means "any signed-in
  user".
- Multiple scopes: nest, or mount twice under different paths.

If you want the mount to simply not exist for non-admins (404 instead of a
redirect to login — no signal that the path is there at all), use
`authenticated` or a routing constraint instead:

```ruby
authenticated :user, ->(u) { u.admin? } do
  mount Wurk::Engine => "/wurk"
end
```

`authenticated` matches only when the check passes; a failing request falls
through the router and 404s.

### Any auth library — routing constraint

A constraint gets the raw `ActionDispatch::Request`, so it works with anything
that leaves identity on the session or a header:

```ruby
# config/routes.rb
class AdminConstraint
  def matches?(request)
    user_id = request.session[:user_id]
    user_id && User.find_by(id: user_id)&.admin?
  end
end

constraints(AdminConstraint.new) do
  mount Wurk::Engine => "/wurk"
end
```

**Route-level gating is not enough on its own if you also expose the standalone
Rack surface** (`run Sidekiq::Web` in a separate `config.ru`) — that path is
mounted elsewhere and must be gated where it's mounted.

---

## 2. `Wurk::Web.use` — Rack middleware

Registers a Rack middleware that wraps the dashboard. Use it when the gate
belongs next to the rest of your Wurk config rather than in `routes.rb`, when
you need HTTP Basic auth, or when the check needs to run for both the engine
mount and the standalone Rack app.

```ruby
# config/initializers/wurk.rb
Wurk::Web.use(MyAuthMiddleware, some: "arg") { |env| … }
```

- `*args` and the optional block pass straight through to the middleware's
  `new`.
- Multiple calls stack **outermost-first** (first registered runs first).
- A middleware that returns `401`/`403`/a redirect short-circuits — the
  dashboard never sees the request.
- **Call it at boot, from an initializer.** The chain is built on first request
  and memoized (it rebuilds if the middleware list changes, but don't rely on
  that in production).
- It runs **before** the `authorization` hook, so by the time that block runs,
  `env` is fully populated (e.g. `env['warden']`).

### Devise / Warden

Devise builds on Warden, which is already in your middleware stack and has set
`env['warden']` before the request reaches the mount:

```ruby
# config/initializers/wurk.rb
class WurkAdminAuth
  def initialize(app) = @app = app

  def call(env)
    user = env["warden"]&.user
    return @app.call(env) if user&.admin?

    # 401 → Devise failure app → redirect to /users/sign_in with a return-to.
    env["warden"]&.authenticate!(scope: :user)
    [403, { "Content-Type" => "text/plain" }, ["Forbidden"]]
  end
end

Wurk::Web.use(WurkAdminAuth)
```

`warden.authenticate!` throws `:warden`, which Warden's own manager catches and
turns into your Devise failure app's response — that's why the `403` line is
only reached for a signed-in non-admin.

Scoped variants:

```ruby
user = env["warden"]&.user(:admin_user)          # a non-default Devise scope
return @app.call(env) if env["warden"]&.authenticated?(:admin_user)
```

### Sorcery

Sorcery exposes its helpers on the controller, not on `env`, so read the
session directly:

```ruby
class WurkSorceryAuth
  def initialize(app) = @app = app

  def call(env)
    user_id = env["rack.session"]&.[](:user_id)
    admin   = user_id && User.find_by(id: user_id)&.admin?
    return @app.call(env) if admin

    [302, { "Location" => "/login", "Content-Type" => "text/plain" }, ["Redirecting"]]
  end
end

Wurk::Web.use(WurkSorceryAuth)
```

The same shape works for `has_secure_password`, Clearance, Rodauth, or any
hand-rolled session — swap the session key lookup.

### HTTP Basic auth

For an internal tool with no host-app coupling. Use constant-time comparison so
the credentials aren't guessable byte-by-byte:

```ruby
Wurk::Web.use(Rack::Auth::Basic, "Wurk") do |user, password|
  ActiveSupport::SecurityUtils.secure_compare(user, ENV.fetch("WURK_USER")) &
    ActiveSupport::SecurityUtils.secure_compare(password, ENV.fetch("WURK_PASS"))
end
```

Note the single `&` — it evaluates both comparisons regardless, so the response
time doesn't leak whether the username matched.

### API tokens / service-to-service

Header check, no session involved:

```ruby
class WurkTokenAuth
  def initialize(app) = @app = app

  def call(env)
    token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
    return @app.call(env) if ActiveSupport::SecurityUtils.secure_compare(token, ENV.fetch("WURK_TOKEN"))

    [401, { "Content-Type" => "text/plain", "WWW-Authenticate" => "Bearer" }, ["Unauthorized"]]
  end
end

Wurk::Web.use(WurkTokenAuth)
```

Bearer-token clients don't carry an ambient cookie, but they also don't send
`Sec-Fetch-Site` — see [§ CSRF](#csrf) for what that means for mutating calls.

---

## 3. `authorization` — per-request, method- and path-aware

Route gates and `use` middleware answer "who are you". The authorization hook
answers "may *this* request do *this*". Use it when read access and write
access have different audiences — e.g. support staff may look at queues, only
admins may retry or kill.

```ruby
# config/initializers/wurk.rb
Wurk::Web.configure do |c|
  c.authorization do |env, method, _path|
    user = env["warden"]&.user
    method == "GET" ? (user&.support? || user&.admin?) : user&.admin?
  end
end
```

- A **falsey** return short-circuits with `403 Forbidden`.
- `method` is the HTTP verb; `path` is **engine-relative** (`/api/stats`, not
  the host's absolute `/wurk/api/stats`) — matching Sidekiq's contract, so a
  block written for Sidekiq keeps working regardless of mount path.
- It runs **after** any `Wurk::Web.use` middleware, so `env` already carries
  whatever they set.
- Registered once, globally. There's no per-mount variant.

> **Engine-nested machine API.** The host authorization hook also gates requests
> to `/wurk/api/v1` when the engine is mounted at `/wurk`; the hook sees the
> engine-relative path `/api/v1`. It runs before the handoff to `Wurk::API` and
> its bearer authentication. A hook that requires a logged-in session can
> therefore return `403 Forbidden` even when the request carries a valid bearer
> token. This inheritance does not apply to separately mounted or standalone
> `Wurk::API`.

Path-scoped example — everyone with access may view, but the retry/kill
endpoints need an explicit role:

```ruby
Wurk::Web.configure do |c|
  c.authorization do |env, method, path|
    user = env["warden"]&.user
    next false unless user

    next true if method == "GET"
    next user.admin? if path.start_with?("/api/retries", "/api/dead")

    user.operator?
  end
end
```

The SPA reads its own capability from `GET /api/meta`: when the hook denies
mutations for the current request, `meta.read_only` comes back `true` and the
UI hides destructive actions instead of offering buttons that 403.

---

## 4. Read-only mode

For a viewer-only deploy (a public demo, a shared status board), skip auth code
entirely:

```bash
WURK_WEB_READ_ONLY=1
```

Every non-`GET`/`HEAD`/`OPTIONS` request returns `403 Read-only mode`, and the
SPA hides destructive actions. The Ruby equivalent, plus an optional banner
message:

```ruby
Wurk::Web.configure do |c|
  c.read_only = true
  c.read_only_message = "Production board — retries are handled by on-call."
end
```

`read_only=` also accepts strings, so `c.read_only = ENV["READONLY"]` does what
you expect (`"0"`, `"false"`, `""`, `"no"`, `"off"` mean off).

Read-only is a **blanket** control — it is not a substitute for authentication.
Anyone who can reach the mount can still read every job payload.

---

## CSRF

The dashboard is a cookie-authenticated SPA that sends no Rails authenticity
token, so `protect_from_forgery` doesn't apply. Wurk uses Sidekiq 8's model
instead: **every mutating request must come from the dashboard's own origin**.

- With `Sec-Fetch-Site` present, it must be `same-origin`. Browsers set that
  header themselves; a cross-site page can drive a victim's browser but cannot
  forge it.
- Browsers send `Sec-Fetch-Site` only to a potentially-trustworthy origin:
  HTTPS, or `localhost`. A dashboard served over plain HTTP from any other host
  (a LAN IP, an internal hostname) never gets it. Without it, the engine
  compares the request's `Origin` header — or, when there is none, its
  `Referer` — with the request's own scheme, host and port. They must match
  exactly: `http://jobs.internal:8080` is not `http://jobs.internal` or
  `https://jobs.internal:8080`. Browsers send `Origin` on every `fetch` POST,
  so the SPA passes this check.
- **Neither header present is denied.** Only a non-browser client omits all
  three, and it carries no ambient session cookie to abuse.
- A refusal is `403` with the JSON body `{"error":"cross_origin"}`; the SPA
  shows it as a cross-origin refusal, not as read-only mode.
- `GET`, `HEAD`, `OPTIONS`, `TRACE` are exempt.
- Enforced identically on the JSON API, extension routes and the profile
  upload. The standalone Rack surface
  ([below](#the-standalone-sidekiqweb-mount)) still requires
  `Sec-Fetch-Site: same-origin`, as Sidekiq does.

Behind a reverse proxy, "the request's own" scheme, host and port are what Rails
reads from it: `Host` (or `X-Forwarded-Host` when the app trusts the proxy),
`X-Forwarded-Proto` and `X-Forwarded-Port`. A proxy that rewrites `Host`
without forwarding the original makes every plain-HTTP mutation look
cross-origin. Serve the dashboard over HTTPS and the `Sec-Fetch-Site` path
applies instead.

Consequence for scripting: a `curl`/service client **cannot** POST to the
dashboard API unless it sends `Sec-Fetch-Site: same-origin` or a matching
`Origin` explicitly. That's deliberate. Prefer driving Wurk through its Ruby API
(`Wurk::Queue`, `Wurk::RetrySet`, …) or the [HTTP API](api-http.md) from
your own authenticated endpoint rather than scripting the dashboard.

`Sidekiq::Web.configure { |c| c[:csrf] = false }` is accepted for
compatibility (the setting round-trips) but does not disable the same-origin
guard.

### Profile uploads

Sidekiq's Profiles page uploads a profile to the public Firefox profiler on a
`GET /profiles/:key`. Sending job data to a third party is a side effect, so in
Wurk only `POST /profiles/:key` uploads, under the same-origin rule above, and
read-only mode refuses it. `GET /profiles/:key` redirects to an upload that
already exists (made by either UI) and otherwise answers `405` with
`Allow: POST`.

---

## What is *not* gated

**`/wurk-assets/*` — the precompiled SPA bundle — is served unauthenticated, by
design.** It's mounted into the host's middleware stack ahead of the engine's
routes, so it never reaches `Wurk::Web.use` or the `authorization` hook.

This is safe because the bundle carries no data: no job payloads, no Redis
reads, nothing per-user. It's a static shell, the same trust model as any Rails
app's `public/assets`. Everything data-bearing (stats, queues, jobs, metrics)
is served by the JSON API, which **is** gated by all four controls above.

If compliance requires that even the *existence* of the bundle stay secret, put
a reverse-proxy rule in front of `/wurk-assets` — don't rely on the engine.

---

## The standalone `Sidekiq::Web` mount

`mount Sidekiq::Web => "/sidekiq"`, `run Sidekiq::Web` and `Sidekiq::Web.call(env)`
reach a smaller Rack app than the engine: it serves registered third-party
extension routes (sidekiq-cron's `/cron`, …) at their own paths and 404s
everything else — the full dashboard is the engine mount.

It is gated exactly like the engine. Sidekiq Enterprise puts `authorization`
and read-only in front of `mount Sidekiq::Web`, and Wurk ships Enterprise, so an
app that swapped the gem keeps its gates on that mount:

| Control | Standalone mount |
|---------|------------------|
| Route-level gate | Yes — wrap the `mount` in `authenticate`/`constraints` as in §1 |
| `Wurk::Web.use` | Yes — runs first, so its `env` reaches `authorization` |
| `authorization` | Yes — `path` is relative to the mount (`/cron`, not `/sidekiq/cron`) |
| `read_only` | Yes — every non-`GET`/`HEAD`/`OPTIONS` request is `403 Read-only mode` |
| Same-origin CSRF | Yes — see [§ CSRF](#csrf) |

The CSRF check is not authentication: `curl` can send `Sec-Fetch-Site:
same-origin` itself. Anything that must stay private on this mount needs a
route gate, `Wurk::Web.use`, or an `authorization` block, the same as the
engine.

---

## Recommended production setup

Belt and braces — a route gate so unauthenticated traffic never touches the
engine, plus a role hook so read and write differ:

```ruby
# config/routes.rb
authenticate :user, ->(u) { u.staff? } do
  mount Wurk::Engine => "/wurk"
end
```

```ruby
# config/initializers/wurk.rb
Wurk::Web.configure do |c|
  c.authorization do |env, method, _path|
    method == "GET" || env["warden"]&.user&.admin?
  end
end
```

Then verify, once, against the real deploy:

```bash
curl -si https://app.example.com/wurk/            # → 302 to login (or 404 with `authenticated`)
curl -si https://app.example.com/wurk/api/stats   # → 302/403, never 200
curl -si -X POST https://app.example.com/wurk/api/queues/default/clear  # → 403
```

---

## Related

- [Securing the dashboard & web extensions](dashboard.md) — dashboard config
  and third-party tab registration.
- [Deployment](deployment.md) — where the dashboard runs and what it needs.
