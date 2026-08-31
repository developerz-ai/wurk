# Kubernetes Probes

Opt in to a thin HTTP listener for liveness/readiness:

```ruby
Wurk.configure_server do |config|
  config.health_check(port: 7433)
end
```

| Path | Meaning |
|---|---|
| `/live` | 200 while the Launcher is running; 503 once `stop`/`quiet` is called. |
| `/ready` | 200 only when Redis is reachable **and** the heartbeat fired within `ready_window` (default 30s); 503 otherwise. |

Knobs: `health_check(port:, bind: "0.0.0.0", ready_window: 30)`. In swarm mode only the first child to `start` binds the port.

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
