# On-Demand Port Assignment - Proposal

**Status:** Accepted
**Date:** 2026-04-27
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/11
**Synced:** 2026-04-27 (no comments)
**Refined:** 2026-04-27 (2 rounds)

## Summary

Move port assignment from config parsing to app startup. Caddy starts
with a static Caddyfile where all routes point to the control
interface. When an app starts, Bates assigns a port and uses Caddy's
admin API to update the route's upstream to the real port. On stop,
the port is released and the route reverts to the control interface.

---

## Problem

Ports are assigned during config parsing. Every configured service gets
a port via `PortNumber.next()` regardless of whether it ever starts.
This couples a runtime concern (port allocation) to the configuration
layer.

Because the Caddyfile is generated once at startup with all ports
baked in, this also means Caddy gets routes for services that may never
run. If ports were deferred, the current Caddyfile approach would
require regeneration and reload on every app start — bolting dynamism
onto a static design.

---

## Decided

**Port assignment:**
- Tyler: services start with `port: nil` in config; ports assigned in
  `App.up/1` when services actually start.
- Tyler: all ports defer to `App.up/1`, including manually specified
  ports (`port = 8080`). Single code path — config stores the declared
  value, App assigns it at start time.
- Tyler: assigned port stored in a separate `assigned_port` field in
  the GenServer service state. `config.port` stays as the declared
  value (`nil` for auto, integer for static). This preserves the
  static vs dynamic distinction for debugging and reuse logic.

**Caddy management:**
- Tyler + Claude: Caddy starts with a static Caddyfile where every
  routable service has a route pointing to the control interface. A
  `*.test` catch-all is included for unknown hostnames (typos, stale
  bookmarks) to provide a friendly error via the control interface.
- Tyler + Claude: when an app starts and gets a port, Bates uses
  Caddy's admin API to update the route's upstream to the assigned
  port (adding the `handle_errors` fallback at the same time). This
  is a targeted update using `@id` tags for stable route
  identification, not a full config reload.
- Tyler: Caddy's admin API listens on a unix socket (e.g.,
  `/tmp/bates-caddy.sock`) to avoid port conflicts with user
  applications.
- Tyler: the Caddy upstream is updated on port assignment in `up/1`,
  before the readiness check. During the starting window, Caddy's
  `handle_errors` fallback routes connection-refused to the control
  interface (loading page), which is correct behavior.
- Tyler: App notifies Caddy via synchronous calls
  (`Caddy.update_route/2` on start, `Caddy.revert_route/1` on stop).
  Synchronous calls avoid race conditions on rapid restart cycles
  since the GenServer mailbox serializes them.

**Caddy failure handling:**
- Tyler: if `Caddy.update_route/2` fails on `App.up/1` (e.g., Caddy
  crashed), the app starts anyway and logs a warning. The app is
  running but not routable until Caddy recovers. On Caddy crash
  recovery, routes for running apps are re-registered automatically.
  This keeps process management independent of routing.

**Stop behavior:**
- Tyler: on stop, the assigned port is released and the Caddy route
  reverts to pointing at the control interface (no `handle_errors`
  needed since there's no app upstream). Each start is a fresh port
  assignment and Caddy update.

**Specs:**
- Tyler: spec updates (`process-management.md`, `routing.md`) are part
  of the execution plan, not deferred to `/reconcile`.

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted
> or executed. These are pointers to help orient, not implementation
> instructions.

- **Config**: `source/lib/bates/config.ex` — parses TOML, builds
  `{name, root, services}` tuples. Calls `PortNumber.next()` in
  `build_single_service/2` (line 33) and `resolve_port/2` (line 59)
  to assign ports at parse time.

- **Service struct**: `source/lib/bates/service.ex` — `%Service{}`
  with `name`, `command`, `port`, `hostname`, `middleware`. Port is
  already nullable (workers use `nil`).

- **PortNumber**: `source/lib/bates/port_number.ex` — opens a TCP
  socket on port 0 to get an OS-assigned port. Stateless, no GenServer.

- **App GenServer**: `source/lib/bates/app.ex` — manages service
  lifecycles. `start_service/3` (line 220) reads `config.port` to set
  `$PORT` env var and decide whether to poll for readiness. Services
  with `port: nil` skip readiness polling and go straight to "up."

- **Caddy GenServer**: `source/lib/bates/caddy.ex` — starts Caddy via
  `caddy run --adapter caddyfile -c -`, pipes a generated Caddyfile to
  stdin. `generate_caddyfile/0` iterates all app services and builds a
  route per routable service (those with a hostname). No runtime config
  changes — Caddy is started once and left alone.

- **ProcessSupervisor**: `source/lib/bates/process_supervisor.ex` —
  `hostname_lookup/0` builds a `%{hostname => app_name}` map from live
  service data. Used by `AppRedirect` to resolve hostnames.

- **AppRedirect plug**: `source/lib/bates_web/plugs/app_redirect.ex` —
  calls `hostname_lookup/0` to map request hostname to app name. Returns
  404 for unknown hostnames. This lookup depends on service hostname
  being set at config time (which it is — hostname comes from TOML, not
  from port assignment).

- **Supervision tree**: `source/lib/bates/application.ex` — starts
  Registry, PubSub, ProcessSupervisor, Endpoint, then Caddy (in that
  order). Caddy starts last because it queries ProcessSupervisor for
  routes.

- **Tests**: `source/test/bates/config_test.exs` asserts
  `is_integer(service.port)` for routable services.
  `source/test/bates/app_test.exs` uses `PortNumber.next()` in test
  setup to assign ports manually. No Caddy tests exist.

---

## Proposed Design

### Port assignment moves to App

`Config` stops calling `PortNumber.next()`. All services get
`port: nil` from config (for auto-assigned) or the explicit integer
(for `port = 8080`). The `hostname` field distinguishes "routable but
not yet assigned" from "not routable."

When `App.up/1` starts services, it assigns a port to any service that
needs one: auto-assigned services get a `PortNumber.next()` call,
static-port services use their declared value. The assigned port is
stored in a new `assigned_port` field in the GenServer's service state,
separate from `config.port`. All runtime code (`env_with_port`,
`check_ready`, `services/1`) reads from `assigned_port`.

On stop, the assigned port is released (`assigned_port` set back to
`nil`). Each start cycle gets a fresh port assignment.

### Caddy: static routes with dynamic upstreams

Caddy starts with a complete Caddyfile generated at startup. Every
routable service gets a route pointing to the control interface. A
`*.test` catch-all provides friendly errors for unknown hostnames.
This means every configured hostname is routable from the moment
Caddy starts — on-demand startup works immediately via `AppRedirect`.

When `App.up/1` assigns a port, it calls `Caddy.update_route/2`
synchronously, which uses the admin API (over a unix socket) to
update that route's upstream to the assigned port and add the
`handle_errors` fallback block. Each route is given a stable `@id`
tag in the initial config so the admin API can target it by
identifier rather than by index path. When `App.down/1` stops a
service, it calls `Caddy.revert_route/1` to point the route back at
the control interface only.

Caddy's admin API listens on a unix socket to avoid port conflicts.

On Caddy crash recovery, the Caddyfile is regenerated (all routes
pointing to control interface), and routes for any currently-running
apps are re-registered via the admin API.

### Hostname lookup stays the same

`ProcessSupervisor.hostname_lookup/0` already derives the
hostname-to-app mapping from service config, which includes `hostname`
regardless of port assignment. No changes needed.

---

## What This Unlocks

1. Ports are only allocated for apps that actually start — no wasted
   OS resources for idle apps.
2. Config parsing becomes pure data transformation with no side effects.
3. Caddy routes reflect actual runtime state instead of theoretical
   config.
4. Foundation for future features that need dynamic route management
   (custom domains, route-level middleware).

---

## Scope

- **Config**: remove `PortNumber.next()` calls, services start with
  `port: nil` (auto) or the declared integer (static)
- **App GenServer**: add `assigned_port` to service state, assign
  ports in `up/1`, release on `down/1`, notify Caddy on both
- **Caddy GenServer**: generate initial Caddyfile with all routes to
  control interface plus catch-all, add admin API functions to update
  and revert route upstreams, configure unix socket for admin API
- **Tests**: update config tests (no port assertions for auto
  services), update app tests (port assignment on start), add Caddy
  admin API tests
- **Specs**: update `process-management.md` (port assignment timing)
  and `routing.md` (dynamic upstream updates)
- **No changes to**: Service struct (beyond what config already
  provides), AppRedirect plug, dashboard, loading page,
  ProcessSupervisor, CLI/API endpoints

---

## Open Questions

None. All questions resolved during refinement and audit.
