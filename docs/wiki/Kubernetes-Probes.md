# Kubernetes Probes

Opt in to a thin HTTP listener for liveness/readiness and Prometheus metrics:

```ruby
Wurk.configure_server do |config|
  config.health_check(port: 7433)
end
```

| Path | Meaning |
|---|---|
| `/live` | 200 while the Launcher is running; 503 once `stop`/`quiet` is called. |
| `/ready` | 200 only when Redis is reachable **and** the local heartbeat fired within `ready_window` (default 30s); in swarm mode, enough children must also have fresh heartbeats (see `min_ready` below). 503 otherwise. |
| `/metrics` | Prometheus text exposition, enabled by default. Set `metrics: false` to disable this endpoint (404). |

Knobs: `health_check(port:, bind: "0.0.0.0", ready_window: 30, metrics: true, min_ready: nil)`. In swarm mode only the first child to `start` binds the port.

In swarm mode, `min_ready` is a positive integer override for the number of children whose heartbeats must be fresh within `ready_window` for `/ready` to return 200, in addition to the listener's local Redis and heartbeat checks. The default, `nil`, requires half the configured children, rounded up. An explicit threshold is capped at the configured fleet size. Outside swarm mode, `min_ready` does not add a fleet requirement: readiness retains only the local Redis and heartbeat checks.

```yaml
livenessProbe:
  httpGet: { path: /live, port: 7433 }
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet: { path: /ready, port: 7433 }
  periodSeconds: 5
  failureThreshold: 2
```
