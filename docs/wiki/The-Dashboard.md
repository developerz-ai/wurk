# The Dashboard

Mount the engine anywhere:

```ruby
# config/routes.rb
mount Wurk::Engine => "/wurk"
```

The precompiled SolidJS SPA ships inside the gem, so consumers never run Node. It uses SSE for live updates and shows queues, retries, scheduled, dead, batches, limiters, periodic jobs, and throughput/failure charts.

## Securing it

The dashboard ships **no session layer of its own** — gate it behind your app's existing auth. Two hooks:

### `Wurk::Web.use` — any Rack middleware

```ruby
# config/initializers/wurk.rb
Wurk::Web.use(Rack::Auth::Basic, "Wurk") do |user, password|
  ActiveSupport::SecurityUtils.secure_compare(user, ENV["WURK_USER"]) &
    ActiveSupport::SecurityUtils.secure_compare(password, ENV["WURK_PASS"])
end
```

This is Sidekiq-compatible (`Sidekiq::Web.use` is aliased to it). For Devise/Warden, gate with a small middleware that checks `env["warden"].user`; for Sorcery, check the session. Middleware registered here runs **before** the authorization hook below.

### Authorization hook — per-request role checks

```ruby
Wurk::Web.configure do |c|
  c.authorization do |env, method, _path|
    user = env["warden"]&.user
    method == "GET" ? (user&.support? || user&.admin?) : user&.admin?
  end
end
```

A falsey return short-circuits to `403`.

## Read-only mode

Ship a viewer-only board (e.g. a public demo) with no auth code at all:

```sh
WURK_WEB_READ_ONLY=1
```

Every mutating request (retry/kill/requeue/pause/clear) returns **403** at the middleware layer, and the SPA hides the destructive actions.

> The dashboard runs in your **web** process (Puma), not the worker — configure it there.
