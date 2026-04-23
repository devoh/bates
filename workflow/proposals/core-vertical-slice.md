# Core Vertical Slice - Proposal

**Status:** Draft
**Date:** 2026-04-23
**Author:** Tyler + Claude
**Refined:** 2026-04-23

## Summary

Replace Conjure's custom DNS server, HTTP reverse proxy, and IPC control
interface with Caddy, Phoenix LiveView, and the macOS resolver. Validate
the new architecture end to end with a single-service application: read
the TOML config, start one process with a dynamic port, proxy HTTPS
traffic through Caddy, and serve a loading page that triggers on-demand
startup.

---

## Problem

Conjure has a working core — process management, TOML config loading,
port allocation — but the infrastructure around it (custom DNS server,
hand-rolled TCP reverse proxy, Unix socket IPC) doesn't match the
target architecture described in the specs. The specs call for Caddy
(SSL, HTTP/2, WebSockets for free), Phoenix LiveView (real-time
dashboard and loading page), and the macOS resolver (no custom DNS
server needed).

Before building out multi-service support, middleware, or the full
dashboard, the new architectural foundation needs to be proven. This
proposal is that proof: one app, one service, one request path, end to
end.

---

## Decided

### Caddy fallback mechanism

Caddy's `handle_response` directive does NOT fire on connection refused
— it only intercepts actual HTTP responses from upstreams. When an
upstream is unreachable, Caddy generates a 502 internally. The correct
directive is `handle_errors`, which catches Caddy's internal error
responses. Verified with a spike against Caddy v2.9.1. The sandbox
implementation notes have been updated with the correct Caddyfile
pattern.

### LiveView WebSocket routing

The LiveView WebSocket connects to `conjure.test`, not the app's
hostname. The initial page load hits `myapp.test` → Caddy fallback →
Phoenix serves the loading page HTML with the app name embedded as a
LiveView param. The LiveView JavaScript then opens its WebSocket to
`conjure.test` directly (no fallback path needed for WebSockets).
Phoenix only needs to handle `conjure.test` for LiveView connections.

### Caddy binary

Assume Caddy is in `$PATH` (installed via Homebrew). Add a
prerequisite check on startup alongside the resolver file and trust
store checks. If `caddy` isn't found, exit with a message. Don't
bundle or auto-install.

### Config field names

Rename `dir` → `root` and `env` → `environment` in this proposal.
Keep `$PORT` string substitution in commands as a stopgap until
middleware lands. No backward compatibility needed — there are no
external users yet.

### Hostname field

Skip for this proposal. The single-service shorthand implies every
configured app is routable by its name. Introduce the `hostname` field
when multi-service support lands.

### Config file location

Defer to the CLI proposal. Keep reading `config.toml` from the current
directory for now.

### Setup workflow

Document manual setup steps in the README (create
`/etc/resolver/test`, run `caddy trust`). The `conjure setup` command
comes with the CLI proposal.

### Port allocation

Defer dynamic detection (bind-to-0). Keep the existing monotonic
allocator starting at 4200. Change it in a follow-up proposal.

### Test strategy

Include a minimal Elixir test app in the repo that binds to `$PORT`
and responds with 200 — no external runtime dependencies. Manual
end-to-end verification for this proposal. Fix the broken port number
test. Automated integration tests can come later once the architecture
stabilizes.

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted
> or executed. These are pointers to help orient, not implementation
> instructions.

### What exists and stays

- **`source/lib/conjure/process.ex`** — GenServer per application.
  Manages OS process lifecycle (up/down/crashed) via `erlexec`. Has
  port assignment, environment variable passthrough, stdout/stderr
  logging. This is the core and it works.

- **`source/lib/conjure/process_supervisor.ex`** — DynamicSupervisor.
  Loads processes from TOML config, starts Process children, provides
  status and hostname lookups.

- **`source/lib/conjure/config.ex`** — Reads and parses `config.toml`,
  builds Process structs from TOML sections.

- **`source/lib/conjure/port_number.ex`** — Agent-based port allocator,
  monotonically incrementing from 4200.

### What gets replaced

- **`source/lib/conjure/dns_server.ex`** — Custom UDP DNS server on
  port 42000. Replaced by macOS `/etc/resolver/test` pointing to
  `127.0.0.1`.

- **`source/lib/conjure/proxy.ex`** — Hand-rolled TCP reverse proxy on
  port 42001 using `:gen_tcp`. Replaced by Caddy with generated
  Caddyfile.

- **`source/lib/conjure/request.ex`** — Per-request TCP forwarder with
  chunked encoding support. Replaced by Caddy.

- **`source/lib/conjure/http.ex`** — HTTP response formatting helpers
  for the custom proxy. Replaced by Caddy.

- **`source/lib/conjure/ipc_server.ex`** — Unix socket IPC with JSON
  commands (up/down/status). Replaced by Phoenix JSON API and LiveView.

### What doesn't exist yet

- No Phoenix dependency, no web framework at all.
- No Caddy integration (no Caddyfile generation, no process management
  for Caddy itself).
- No CLI (no `conjure start`, `conjure setup`, etc.).
- No LiveView (no dashboard, no loading page).

### What needs updating

- **`source/lib/conjure/application.ex`** — Supervision tree currently
  starts the DNS server, IPC server, and proxy. Needs to start Caddy
  and Phoenix instead.

- **`source/lib/conjure/config.ex`** — Field names need updating:
  `dir` → `root`, `env` → `environment`.

- **`source/mix.exs`** — Dependencies include `:dns` (no longer
  needed). Needs `:phoenix`, `:phoenix_live_view`, and related deps.

---

## Proposed Design

### Scope: one app, one service, one path

A single-service TOML config like this works end to end:

```toml
[myapp]
root = "~/Code/myapp"
command = "bin/rails server"
```

The system reads the config, assigns a port, generates a Caddyfile,
starts Caddy, and waits. When a browser hits `myapp.test`:

1. macOS resolver sends it to `127.0.0.1`.
2. Caddy terminates SSL and tries the primary upstream (connection
   refused — app is down).
3. Caddy's `handle_errors` catches the 502 and falls back to the
   control interface.
4. The control interface identifies the app from the `Host` header,
   starts it, and serves a loading page with the app name embedded.
5. The loading page opens a LiveView WebSocket to `conjure.test` with
   the app name as a param. The LiveView subscribes to that app's
   state via PubSub.
6. When the app is ready (port accepting connections), the LiveView
   redirects the browser to the running app.

### Three pieces to build

**Caddy management.** A supervised process that generates a Caddyfile
from the loaded config and starts Caddy as a child process, piping the
config to stdin. If Caddy crashes, it restarts with a fresh Caddyfile.
One route per configured app (using `handle_errors` for the fallback),
plus `conjure.test` for the control interface. Checks for the `caddy`
binary on startup.

**Phoenix control interface.** Add Phoenix as a dependency. The control
interface serves on an internal port (not exposed to users directly —
Caddy proxies `conjure.test` to it). Three pieces for this proposal:

- A loading page (LiveView) that subscribes to process state via
  PubSub. The WebSocket connects to `conjure.test`; the app name is
  passed as a param from the initial fallback page load. Shows the
  app name and status, redirects on ready.
- A fallback page handler that reads the `Host` header to identify
  the target app, triggers startup, and serves the initial HTML that
  bootstraps the LiveView.
- The JSON API endpoints for status, start, and stop (used by the
  CLI later, but useful for testing now).

The full dashboard is out of scope for this proposal.

**Process state broadcasting.** The existing Process GenServer needs to
broadcast state transitions via Phoenix PubSub so LiveViews can
subscribe. This is a small addition to the existing process lifecycle
callbacks.

### What stays as-is

- Process management (GenServer, DynamicSupervisor, erlexec).
- TOML config loading (with field renames).
- Port allocation (monotonic from 4200).
- Single-service config format (no multi-service, no middleware,
  no `hostname` field).
- `$PORT` substitution in commands (stopgap until middleware).

### What gets removed

- DNS server (`dns_server.ex`).
- HTTP proxy (`proxy.ex`, `request.ex`, `http.ex`).
- IPC server (`ipc_server.ex`).
- The `:dns` dependency.

---

## What This Unlocks

1. HTTPS with automatic certificates — no more plain HTTP.
2. HTTP/2 and WebSocket support for free via Caddy.
3. Real-time loading page instead of connection-refused errors.
4. Foundation for the full dashboard, CLI, and multi-service support.
5. Validated architecture that all three domains (process management,
   routing, control interface) connect correctly.

---

## Scope

- **Add:** Phoenix, Phoenix LiveView, Caddy process management,
  Caddyfile generation (using `handle_errors` for fallback), loading
  page LiveView (WebSocket via `conjure.test`), fallback page handler,
  JSON API (status/start/stop), PubSub broadcasting from Process
  GenServer, Elixir test app, manual setup docs in README.
- **Remove:** DNS server, HTTP proxy, request forwarder, HTTP helpers,
  IPC server, `:dns` dependency.
- **Update:** Supervision tree, mix.exs dependencies, config field
  names (`dir` → `root`, `env` → `environment`), broken port number
  test.
- **Keep:** Process GenServer, ProcessSupervisor, Config (structure),
  PortNumber (monotonic), `$PORT` substitution.
- **Defer:** Dashboard, CLI, multi-service, middleware, `hostname`
  field, dynamic port detection, `conjure setup` command, config file
  path change, automated integration tests.

---

## Open Questions

None. All questions resolved during refinement.
