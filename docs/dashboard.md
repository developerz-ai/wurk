# Securing the dashboard

The Wurk dashboard is a mountable Rails engine. It ships **no session layer of
its own** — the first thing every production deploy does is gate it behind the
host app's existing authentication, and Wurk gives you two hooks to do that
without writing a custom Rack middleware.

| Hook | Use it for | API |
|------|------------|-----|
| `Wurk::Web.use` | Drop in any Rack auth middleware (Devise/Warden, `Rack::Auth::Basic`, a custom guard) in front of the dashboard. | `Wurk::Web.use(Middleware, *args, &block)` |
| `Wurk::Web.configure { \|c\| c.authorization { … } }` | A per-request `(env, method, path) -> truthy/falsey` check (e.g. role gating GET vs POST). | see [§ Authorization hook](#authorization-hook) |

Both are Sidekiq-compatible: `Sidekiq::Web.use(...)` is aliased to
`Wurk::Web.use`, so an existing Sidekiq initializer keeps working on the
one-line gem swap.

The two compose. `Wurk::Web.use` middleware runs **first** (outermost), so by
the time the `authorization` block runs, the host middleware has already
populated `env` (e.g. `env['warden']`).

> Scope: these hooks only affect requests routed **under the engine mount**.
> The host app's own controllers are untouched.

## `Wurk::Web.use`

Call it once at boot, from an initializer. The chain is built on the first
request and memoized, so register before the app starts serving.

```ruby
# config/initializers/wurk.rb
Wurk::Web.use(MyAuthMiddleware, some: "arg") { |env| ... }
```

`*args` and the optional block pass straight through to the middleware's
`new`. Multiple calls stack outermost-first. A middleware that returns a
`401`/`403`/redirect short-circuits the request — the dashboard never sees it.

### Devise / Warden

Devise builds on Warden, which is already in your middleware stack and has set
`env['warden']` by the time a request reaches the mount. Gate with a tiny
middleware that bounces unauthenticated users to your login page:

```ruby
# config/initializers/wurk.rb
class WurkAdminAuth
  def initialize(app) = @app = app

  def call(env)
    warden = env["warden"]
    user   = warden&.user
    return @app.call(env) if user&.admin?

    warden&.authenticate!(scope: :user) # 401 → Devise failure app → /users/sign_in
    [403, { "Content-Type" => "text/plain" }, ["Forbidden"]]
  end
end

Wurk::Web.use(WurkAdminAuth)
```

Prefer to keep it in `routes.rb`? `authenticate` works too, and needs no
`Wurk::Web.use`:

```ruby
# config/routes.rb
authenticate :user, ->(u) { u.admin? } do
  mount Wurk::Engine => "/wurk"
end
```

### Sorcery

Sorcery exposes its helpers on the controller, not on `env`, so check the
session directly in the middleware:

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

### Plain HTTP Basic auth

For an internal tool, `Rack::Auth::Basic` is enough — no host-app coupling:

```ruby
Wurk::Web.use(Rack::Auth::Basic, "Wurk") do |user, password|
  ActiveSupport::SecurityUtils.secure_compare(user, ENV["WURK_USER"]) &
    ActiveSupport::SecurityUtils.secure_compare(password, ENV["WURK_PASS"])
end
```

## Authorization hook

For role logic that depends on the HTTP method or path (e.g. support staff may
view but only admins may retry/kill), use the per-request hook instead of (or
alongside) a `use` middleware:

```ruby
Wurk::Web.configure do |c|
  c.authorization do |env, method, _path|
    user = env["warden"]&.user
    method == "GET" ? (user&.support? || user&.admin?) : user&.admin?
  end
end
```

A falsey return short-circuits to `403`. `path` is engine-relative
(`/api/stats`, not the host's absolute `/wurk/api/stats`), matching Sidekiq's
contract.

### Read-only mode

To ship a viewer-only deploy (e.g. a public demo) with **no Ruby config**, set
`WURK_WEB_READ_ONLY=1` — every non-`GET` request 403s and the SPA hides
destructive actions. Equivalent in Ruby:

```ruby
Wurk::Web.configure { |c| c.read_only = true }
```

## Custom tabs / Web extensions

Third-party gems (sidekiq-cron, sidekiq-unique-jobs, sidekiq-status, …) add
their own dashboard tabs through `Sidekiq::Web::Config#register_extension` (alias
`register`). Wurk implements that surface under the `Sidekiq::Web` /
`Wurk::Web` alias, so requiring those gems works unchanged:

`register_extension(extclass, name:, tab:, index:, …)` mirrors Sidekiq: `tab` is
the label, `index` the path, `name` the asset namespace (`tab`/`index` may be
arrays, zipped). Both call styles work — class-level, or inside a configure
block:

```ruby
Sidekiq::Web.register(MyGem::Web, name: "unique_jobs", tab: "Locks", index: "locks")

Sidekiq::Web.configure do |c|
  c.register_extension(MyGem::Web, name: "unique_jobs", tab: "Locks", index: "locks")
  c.tabs["Expiry"] = "expiry"          # the tabs hash (label => path) is directly mutable
  c.custom_job_info_rows << MyGem::Row # collected for job-detail rows
  c.app_url = "https://myapp.example"
end
```

A registered tab whose path isn't one Wurk already renders natively surfaces in
the left-nav (read from `GET /api/meta`). Clicking it opens an in-dashboard
**Extension** page that embeds the extension's own path (`/<mount>/<index>`) in an
iframe. `custom_job_info_rows` render as extra rows in the job-detail modal.

**Supported subset (important).** Wurk's dashboard is a **precompiled React
SPA**, not Sidekiq's server-rendered ERB UI. So:

- **Registration is accepted and no-op-safe** — requiring a gem that calls
  `register`/`register_extension` (or mutates `tabs`) never crashes boot.
- **Tabs surface in the nav** and open an Extension page that iframes the
  extension's path. If the host mounts the gem's own Rack app reachable at that
  path, its view renders in the frame; otherwise the frame shows a short
  "not rendered here" note (no recursive dashboard nesting).
- **`custom_job_info_rows` render** in the job-detail modal — each registered
  callable (`call(job)`) or `add_pair(job)` object contributes a `label/value`
  row.
- **Sidekiq's ERB extension views are _not_ rendered natively.** Sidekiq
  extensions ship ERB templates rendered by a Sinatra app; wurk has no such
  render path, so the gem's own templates aren't compiled into the SPA bundle.

Rendering Sidekiq's ERB extension views natively in the dashboard is tracked as
a follow-up (#187).
