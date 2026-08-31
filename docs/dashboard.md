# Securing the dashboard

> **Full guide: [Authentication & authorization](authentication.md)** — Devise,
> Warden, Sorcery, Basic auth, API tokens, route gates, role-based read/write
> splits, the CSRF model, and what isn't gated. This page is the quick
> reference plus the web-extension surface.

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

### Recipes

The worked middleware for each auth stack lives in one place — [Authentication
& authorization § `Wurk::Web.use`](authentication.md#2-wurkwebuse--rack-middleware):

- [Devise / Warden](authentication.md#devise--warden), including scoped variants
  and the `routes.rb` `authenticate` gate that needs no middleware at all.
- [Sorcery](authentication.md#sorcery) — and the same shape for Clearance,
  Rodauth, `has_secure_password`, or any hand-rolled session.
- [HTTP Basic auth](authentication.md#http-basic-auth) — `Rack::Auth::Basic`
  with constant-time comparison.
- [API tokens / service-to-service](authentication.md#api-tokens--service-to-service).

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
contract. Path-scoped examples and how the SPA learns its own capability:
[Authentication & authorization § `authorization`](authentication.md#3-authorization--per-request-method--and-path-aware).

### Read-only mode

To ship a viewer-only deploy (e.g. a public demo) with **no Ruby config**, set
`WURK_WEB_READ_ONLY=1` — every non-`GET` request 403s and the SPA hides
destructive actions. Equivalent in Ruby:

```ruby
Wurk::Web.configure { |c| c.read_only = true }
```

The banner message, the string coercion `read_only=` accepts, and what
read-only does **not** protect: [Authentication & authorization §
Read-only mode](authentication.md#4-read-only-mode).

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
**Extension** page that renders the extension's view **natively**: the
extension's Sinatra-style routes and ERB views are executed server-side and the
resulting HTML is embedded in the page. `custom_job_info_rows` render as extra
rows in the job-detail modal.

**How native rendering works.** Sidekiq extensions declare routes in
`registered(app)` (`app.get "/locks" do … erb :index end`) and ship ERB
templates under `root_dir/views`. Wurk captures those routes at registration
and serves them Sidekiq-Web-compatibly — no Sinatra involved:

- `GET/POST /<mount>/ext/<name>/<subpath>` matches the extension's route
  (route params like `/locks/:digest` included), runs the block in a
  `WebHelpers`-compatible context (`h`, `t`, `truncate`, `root_path`,
  `asset_path`, `redis`, `params`, `redirect`, `erb`, …), and returns the
  rendered HTML. Links and forms inside the view are intercepted by the SPA so
  navigation stays in-page; `redirect` (e.g. delete → list) is followed
  transparently.
- `GET /<mount>/ext-assets/<name>/<file>` serves files from the extension's
  `asset_paths` (with `Cache-Control` from `cache_for`, path-traversal
  rejected), so a view's `<link href="<%= asset_path('app.css') %>">` works.
- Locale strings load from `root_dir/locales/en.yml` and resolve through the
  `t` helper; missing keys degrade to the humanized key, never raise.
- CSRF matches Sidekiq's model: non-`GET` extension requests must be
  same-origin per `Sec-Fetch-Site`; cross-site requests are denied.
- Tabs added by bare `tabs["Label"] = "path"` mutation have no extension to
  render; those fall back to an Extension page that iframes the tab's own path
  (if the host mounts something reachable there, it renders in the frame).
- Registration stays no-op-safe — a gem calling `register`/`register_extension`
  (or mutating `tabs`) never crashes boot.

**Scope note.** This renders extensions registered against wurk's
`Sidekiq::Web` alias. Gems that literally `require "sidekiq"` still can't load
against wurk (wurk intentionally does not depend on — or install — the sidekiq
gem; the consumer app shouldn't either, since wurk's native unique-jobs / cron /
batches / limiter replace the common ecosystem gems). A `require "sidekiq"`
compatibility shim is tracked, deliberately deferred, in #204.

## Language, theme, and timezone

Not security settings, but the other three per-visitor things a host shapes
server-side. `config.web.offered_locales` is the *supported set*, not a
default: the dashboard negotiates it against the visitor's `Accept-Language`
header (`negotiated_locale` in `Wurk::DashboardController`, backed by
`Wurk::Web::LocaleNegotiator`). `config.web.default_locale` is the fallback
used when nothing in that header matches the offered set, and
`config.web.default_theme` is the palette default. All three are read
server-side and injected ahead of the shell's pre-paint script, so a visitor's
first load already renders in the right language and palette instead of
flashing the wrong one. Timezone has no server-side hint at all — it's resolved
entirely client-side from the browser's own zone, or a visitor's own override.
Full reference, including precedence order
and every option: [Configuration → Dashboard configuration](configuration.md#dashboard-configuration).
