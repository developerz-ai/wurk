---
name: run-dashboard
description: Boot the Wurk dashboard against the dummy app and see a change working in the browser. Use when a change touches frontend/, app/, or dashboard JSON, or when asked to run or screenshot the dashboard.
---

# run-dashboard

1. `bin/setup` once on a fresh checkout. `bin/dev` needs it; a bare `cd test/dummy && bin/rails s` fails with "Could not find rails-…" until the dummy app's gems are installed.
2. `bin/dev` in the background: Redis (`REDIS_URL`, else its own `bin/redis up dev` server, never :6379), Vite HMR on `VITE_PORT` (5173), Rails on `PORT` (3000). `NO_VITE=1` serves the prebuilt bundle (`bin/rake frontend:build` first).
3. Open **http://localhost:3000/wurk**. Port 5173 alone serves assets under `/wurk-assets/`, not the app.
4. Drive the route you changed with the `ui-debugger` MCP (`.ui-debugger-mcp.json`). Check light, dark and a narrow viewport, and an RTL locale when layout moved.
5. Stop `bin/dev` when done. It cleans up what it started.

A passing typecheck is not a working page. Say what you drove and what you saw.
