# Multi-Service Support — Proposal

**Status:** Accepted
**Date:** 2026-04-27
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/4
**Synced:** 2026-04-27 (no comments on issue)
**Refined:** 2026-04-27

## Summary

An application should be able to run multiple services — a web server, a
background worker, a Vite dev server — under one name in the configuration.
Today, each TOML section maps to exactly one OS process. This proposal
introduces the application/service hierarchy so that starting an app starts
all its services, each service gets its own lifecycle, and routable services
each get their own Caddy route and hostname.

---

## Problem

The spec defines applications as groups of related services, but the
implementation only supports the single-service shorthand. A Rails app that
needs a web server, a Sidekiq worker, and a Vite dev server has to be
configured as three separate top-level TOML entries with no relationship
between them. There is no way to start or stop them as a unit, no way to
give them separate hostnames under the same application, and the dashboard
shows them as unrelated processes.

---

## Decided

**From the spec:**

- **Configuration format**: multi-service apps use `[app.services.name]`
  subtables. Single-service shorthand (`command` on the app table) remains
  valid and is equivalent to one routable service.
- **Hostname field**: `true` uses the application name (e.g., `myapp` →
  `myapp.test`). A string value is a custom hostname (e.g., `"vite.myapp"`
  → `vite.myapp.test`).
- **Port field**: defaults to `"auto"` when `hostname` is set. Can be a
  fixed number. Services with neither `port` nor `hostname` are portless
  companions.
- **Application status derivation**: all up → up, all down → down, any
  crashed → crashed, otherwise → partial.
- **On-demand startup**: starts the full application, not just the
  triggered service.
- **Middleware**: can be specified at both application and service level.
  (Separate issue — this proposal does not implement middleware, but the
  data model should accommodate it.)

**From refinement:**

- **Single GenServer per application.** The Application GenServer manages
  a map of service states (pid, ready, log buffer, etc.) keyed by service
  name. No separate GenServer per service — the Application module handles
  all OS process lifecycle, readiness polling, and log buffering for its
  services directly. Tyler: simpler architecture, avoids unnecessary
  inter-process coordination.
- **Concurrent service startup.** All services within an application are
  spawned at the same time. If one crashes while others are still booting,
  the others keep going — the derived status reflects reality (`crashed`
  if any service crashed). No abort-on-failure. Service dependency ordering
  is a future concern.
- **Redirect to originally-requested hostname.** When `vite.myapp.test`
  triggers on-demand startup, the loading page starts the full application
  but subscribes to and waits for the specific service behind that hostname.
  Once that service is ready, it redirects back to `vite.myapp.test` — it
  does not wait for all services to be up. Follows the spec.
- **Partial status controls.** When an app is "partial", the dashboard
  shows Start (brings up stopped/crashed services), Stop (tears down
  everything), and Restart (stop all, then start all).
- **Per-service controls deferred.** The dashboard only exposes
  application-level controls in this proposal. Per-service start/stop is
  a future enhancement. The architecture supports it (services are tracked
  individually in the map) but the UI complexity isn't justified yet.
- **Single-service apps: no nested service row.** The dashboard shows
  only the application row for single-service shorthand apps. Service
  rows appear only when an application has multiple services.
- **Single-service shorthand internal name = app name.** The internal
  service name defaults to the application name. Registry key becomes
  `{"myapp", "myapp"}`. This is purely internal and never shown to the
  user for single-service apps.
- **Log prefix format.** Single-service apps: `[myapp]` (no redundant
  service name). Multi-service apps: `[myapp:web]`, `[myapp:worker]`.
  The prefix omits the service name when it matches the app name.
- **One PR, not phased.** The change touches every module but the
  intermediate state of partially-implemented multi-service is awkward
  and untestable. Ship as one cohesive change.
- **Update specs.** The specs (`process-management.md`,
  `control-interface.md`, `cli.md`) will be updated as part of this work
  to reflect the new API shape and service terminology.

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted or
> executed. These are pointers to help orient, not implementation
> instructions.

**Config parsing** — `source/lib/bates/config.ex`: reads `config.toml`,
iterates top-level TOML tables, converts each to a flat `Bates.Process`
struct. No awareness of nested `services` tables.

**Process struct and GenServer** — `source/lib/bates/process.ex`: the
`Process` struct has `name`, `command`, `root`, `port`, `environment`.
Each process is a GenServer registered in `Bates.ProcessRegistry` by name.
PubSub topic is `"process:#{name}"`. Handles the full lifecycle (down →
starting → up/crashed), readiness polling, log buffering. The `up/1` and
`down/1` API takes a name string.

**ProcessSupervisor** — `source/lib/bates/process_supervisor.ex`:
`DynamicSupervisor` that loads processes from config at startup.
`process_names/0` returns a flat list of registered names from the Registry.
`hostnames/0` maps names to `"#{name}.test"`. `status/0` returns a
`%{hostname => status}` map.

**Caddy** — `source/lib/bates/caddy.ex`: generates a Caddyfile by
iterating `ProcessSupervisor.process_names/0`. Each name gets one Caddy
site block: `#{name}.test` → `reverse_proxy 127.0.0.1:#{port}` with a
`handle_errors` fallback to the control interface. Hostname is hardcoded
as `"#{name}.test"`.

**AppRedirect plug** — `source/lib/bates_web/plugs/app_redirect.ex`:
extracts app name from the request host by trimming `.test` and taking
the first segment after splitting on `.`. This means `vite.myapp.test`
would currently extract `"vite"`, not `"myapp"` — it doesn't handle
multi-segment hostnames.

**Dashboard** — `source/lib/bates_web/live/dashboard_live.ex`: renders a
flat table of processes. Subscribes to `"process:#{name}"` for each.
Controls call `Process.up/1` and `Process.down/1` by name. Builds
hostname as `"#{name}.test"`.

**Loading page** — `source/lib/bates_web/live/loading_live.ex`: takes
`app_name` from URL params, subscribes to `"process:#{app_name}"`, calls
`Process.up(app_name)`, redirects to `https://#{app_name}.test` on up.

**API controller** — `source/lib/bates_web/controllers/process_controller.ex`:
`GET /status` returns a list of `%{name, hostname, status, port}`.
`POST /processes/:name/start` and `/stop` call `Process.up/1` and
`Process.down/1`.

**Port assignment** — `source/lib/bates/port_number.ex`: binds to port 0,
reads OS-assigned port, closes socket. Stateless — called once per process
at init.

**Tests** — `source/test/bates/process_readiness_test.exs` tests single-
process lifecycle. `source/test/bates_web/live/dashboard_live_test.exs`
tests the flat process table. `source/test/bates_web/live/loading_live_test.exs`
tests on-demand startup. `source/test/bates_web/controllers/fallback_controller_test.exs`
tests AppRedirect hostname extraction. `source/test/fixtures/config.toml`
has a single-process config.

---

## Proposed Design

### Two-level data model: Application and Service

The current `Process` module is replaced by an `Application` module — a
single GenServer per application that manages all of its services. Service
configuration is a struct (data only, not a GenServer). The Application
GenServer tracks each service's runtime state in a map keyed by service
name.

**Application** (GenServer) has:
- `name` — the TOML table name
- `root` — working directory (shared by all services)
- `services` — map of service name → service config + runtime state
  (pid, ready, started_at, exit_status, log_buffer)
- `middleware` — application-level middleware names (for future use)

**Service** (struct, not a GenServer) has:
- `name` — the service name within the application (e.g., `web`, `worker`)
- `command` — the shell command
- `port` — auto-assigned or fixed, or `nil` for portless companions
- `hostname` — resolved hostname string (e.g., `"myapp.test"`,
  `"vite.myapp.test"`) or `nil` if not routable
- `middleware` — service-level middleware names (for future use)

The service's working directory comes from the parent application's `root`.

### Registry and naming

Applications register in the Registry by application name. The public API
operates at the application level: `Application.up("myapp")`,
`Application.down("myapp")`. The Application GenServer manages its
services internally.

For the single-service shorthand, the internal service name defaults to
the application name (e.g., `{"myapp", "myapp"}`).

### Config parsing

`Config` parses both formats:

- **Single-service shorthand**: `[myapp]` with `command` directly on the
  table → one Application with one Service (service name = app name,
  `hostname = true`, `port = "auto"`).
- **Multi-service**: `[myapp]` with `[myapp.services.web]` etc. → one
  Application with N services.

The `services` key in TOML is reserved — it cannot be used as an
application name.

### Application lifecycle

The Application GenServer manages all service lifecycles directly. Starting
an application spawns all services concurrently. Stopping an application
stops all services. The application status is derived from service states:

| Condition | Status |
|-----------|--------|
| All services up | up |
| All services down | down |
| Any service crashed | crashed |
| Otherwise | partial |

If one service crashes during startup, the others continue booting. There
is no abort-on-failure — the derived status reflects the current reality.

PubSub broadcasts happen at both levels: per-service on
`"service:#{app_name}:#{service_name}"` and aggregated on
`"app:#{app_name}"`. The dashboard subscribes at the application level.
The loading page subscribes to the specific service that was requested
(identified via hostname lookup) so it can redirect as soon as that
service is ready.

### Caddy route generation

One Caddy site block per routable service (any service with a hostname).
The hostname comes from the service config, not from the application name.
Non-routable services get no Caddy block.

### AppRedirect plug

The plug needs a hostname → application name lookup instead of parsing
the hostname string. The Caddy module already knows which hostnames map
to which applications (it builds the routes). A shared lookup — either a
function on ProcessSupervisor or a simple ETS table populated at init —
lets the plug resolve `"vite.myapp.test"` → `"myapp"` reliably.

### Dashboard

The dashboard groups services by application. Each application row shows
the application name, derived status, and start/stop/restart controls
that operate on the whole application. Multi-service apps show individual
service rows beneath (name, hostname, status, port). Single-service
shorthand apps show only the application row with no nesting.

Controls are application-level only (no per-service controls in this
proposal). For "partial" status, the dashboard shows Start (brings up
stopped/crashed services), Stop, and Restart.

### Loading page

On-demand startup starts the full application. The loading page identifies
which service was originally requested (via hostname lookup), subscribes
to that service's PubSub topic, and redirects back to the original
hostname once that specific service is ready. It does not wait for all
services to be up.

### Logging

Log prefixes reflect the app/service hierarchy. Single-service apps use
`[myapp]`. Multi-service apps use `[myapp:web]`, `[myapp:worker]`. The
rule: omit the service name when it matches the application name.

### API

The API response nests services under applications:

```json
{
  "processes": [
    {
      "name": "myapp",
      "status": "up",
      "services": [
        {"name": "web", "hostname": "myapp.test", "status": "up", "port": 52341},
        {"name": "worker", "status": "up", "port": null}
      ]
    }
  ]
}
```

Start/stop/restart endpoints continue to operate by application name.

---

## What This Unlocks

1. A Rails app with web, worker, and Vite can be configured and managed
   as a single unit.
2. Custom hostnames per service (e.g., `vite.myapp.test` for the asset
   server) with automatic SSL and routing.
3. Application-level status gives a clear picture of health — "partial"
   means something needs attention.
4. Foundation for per-service middleware (issue #5) since the data model
   carries middleware at both levels.

---

## Scope

- **Config**: parse `[app.services.*]` subtables alongside single-service
  shorthand.
- **New module**: `Application` GenServer that replaces `Process`. Single
  GenServer per application managing a map of service states.
- **New struct**: `Service` (data only) for service configuration.
- **Remove**: `Process` module (replaced by `Application`).
- **ProcessSupervisor**: supervises Applications instead of Processes.
  New query functions for hostname → app name lookup.
- **Caddy**: generate routes from services with hostnames, not from
  application names.
- **AppRedirect plug**: look up hostname → app name from a registry
  instead of parsing the hostname string.
- **Dashboard**: group by application, show service rows only for
  multi-service apps. Application-level controls only.
- **Loading page**: start full application, subscribe to requested
  service, redirect to original hostname when that service is ready.
- **API**: nest services under applications in status response.
- **Specs**: update `process-management.md`, `control-interface.md`,
  `cli.md` to reflect the new API shape and terminology.
- **Tests**: update all existing tests, add multi-service config and
  lifecycle tests.
- **No changes to**: port assignment (`PortNumber`), Caddy invocation
  mechanism, PubSub infrastructure, OTP application supervision tree.

---

## Open Questions

None. All questions resolved during refinement — see Decided section.
