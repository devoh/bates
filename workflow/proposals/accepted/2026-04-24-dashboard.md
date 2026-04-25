# Dashboard - Proposal

**Status:** Accepted
**Date:** 2026-04-24
**Refined:** 2026-04-24
**Author:** Tyler + Claude

## Summary

Add a dashboard LiveView at `bates.test` that shows all configured
applications with their status, hostname, and port, with real-time
updates via PubSub and controls to start, stop, and restart each
application.

---

## Problem

Visiting `bates.test` currently returns a 404 from the
FallbackController. There's no way to see which applications are
configured, what state they're in, or control them from a browser.
The JSON API exists (`GET /status`, `POST /processes/:name/start`,
etc.) but there's no human-friendly interface.

Developers have to use `curl` or the CLI to check status and manage
processes. A dashboard provides at-a-glance visibility and one-click
control, which is the expected experience for a local dev server (see
Pow's status endpoint and Puma-dev's status page).

---

## Decided

- **LiveView, not static HTML.** The dashboard uses Phoenix LiveView
  with PubSub subscriptions so status updates appear in real time
  without polling or client-side JavaScript. This matches the loading
  page's approach.
- **Served on `bates.test`.** The dashboard is the default view when
  visiting the control hostname in a browser. The existing API
  endpoints coexist on the same hostname via content negotiation (the
  API routes are in the `:api` pipeline, the dashboard in `:browser`).
- **Per-process PubSub subscriptions.** The dashboard subscribes to
  `process:<name>` for each configured application, receiving state
  transition broadcasts. This is the same mechanism the loading page
  uses.
- **No external CSS framework.** Inline styles, matching the loading
  page's approach. Keeps the dependency footprint minimal.
- **App-domain routing via plug.** A plug in the browser pipeline
  checks `conn.host` against the control hostname. App-domain
  requests are redirected to `/loading/<name>` before they reach any
  LiveView route. This centralizes the host check — the
  FallbackController's host logic becomes redundant and can be
  simplified.
- **Show all four lifecycle states.** The dashboard displays
  "starting" as a distinct status alongside "up", "down", and
  "crashed". It's useful to see that an app is booting.
- **Status label only for crashes.** The dashboard shows "crashed" as
  a status label without inline log output. Crash details are
  available on the loading page or in the terminal. Log display on
  the dashboard is a future proposal.
- **Empty state.** When no processes are configured, the dashboard
  shows a "No applications configured" message.
- **Restart is sequential `down/1` then `up/1`.** The GenServer
  handles these synchronously — `down/1` resets `pid: nil` before
  returning, so `up/1` sees no running process and spawns cleanly.

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted
> or executed. These are pointers to help orient, not implementation
> instructions.

- **ProcessSupervisor** (`source/lib/bates/process_supervisor.ex`) —
  `process_names/0` returns all registered process names from the
  Registry. `status/0` returns a map of hostname to status. These are
  the data sources for the dashboard.
- **Process GenServer** (`source/lib/bates/process.ex`) — Public API:
  `up/1`, `down/1`, `port/1`, `status/1`. Broadcasts on
  `process:<name>` with `{:status, "starting"}`, `{:status, "up"}`,
  `{:status, "down"}`, `{:status, "crashed", log_output}`.
- **ProcessController** (`source/lib/bates_web/controllers/process_controller.ex`) —
  JSON API for status, start, stop. The `status/2` action builds a
  list of process maps with name, hostname, status, and port. The
  dashboard needs the same data but rendered as HTML.
- **LoadingLive** (`source/lib/bates_web/live/loading_live.ex`) —
  Existing LiveView that subscribes to a single process's PubSub topic.
  The dashboard will follow the same pattern but subscribe to all
  processes.
- **FallbackController** (`source/lib/bates_web/controllers/fallback_controller.ex`) —
  Catch-all route. Returns 404 for `bates.test` requests. The
  dashboard will replace this 404 as the default view.
- **Router** (`source/lib/bates_web/router.ex`) — Browser pipeline
  has `live "/loading/:app_name", LoadingLive` and
  `get "/*path", FallbackController, :index`. The dashboard route
  needs to go before the catch-all.
- **Layouts** (`source/lib/bates_web/layouts/`) — Minimal root
  layout with no CSS framework. `app.html.heex` passes through
  `@inner_content` with no wrapper.
- **Tests** — `test/bates_web/live/loading_live_test.exs` (LiveView
  test patterns), `test/bates_web/controllers/fallback_controller_test.exs`
  (controller tests), `test/support/conn_case.ex` (test helper).

---

## Proposed Design

A new `DashboardLive` LiveView mounted at the root path of the control
hostname. On mount, it queries all process names from the
ProcessSupervisor, fetches each process's status and port, and
subscribes to PubSub for each. State transitions update the
corresponding row in real time.

### Data flow

1. `mount/3` calls `ProcessSupervisor.process_names/0` to get all
   configured process names.
2. For each name, calls `Process.status/1` and `Process.port/1` to
   build the initial state.
3. Subscribes to `process:<name>` PubSub topics for each process.
4. `handle_info/2` receives status broadcasts and updates the
   relevant process in assigns.

### Controls

Each process row has contextual controls:

| Status | Available controls |
|--------|--------------------|
| down | Start |
| starting | Stop |
| up | Stop, Restart |
| crashed | Start |

Controls send events to the LiveView (`handle_event/3`), which calls
`Process.up/1`, `Process.down/1`, or both (for restart). No new API
endpoints needed.

### Routing

The dashboard mounts at `live "/", DashboardLive` in the browser
pipeline, before the catch-all. The FallbackController continues to
handle non-root paths on `bates.test` (returning 404) and app
domain redirects.

---

## What This Unlocks

1. At-a-glance visibility into all configured applications and their
   current state.
2. One-click start, stop, and restart from the browser.
3. Real-time status updates without manual refresh.
4. A landing page for `bates.test` instead of a 404.

---

## Scope

- New LiveView: `DashboardLive`
- Route: `live "/", DashboardLive` added to browser pipeline
- No new API endpoints (controls call Process API directly)
- No changes to Process, ProcessSupervisor, or PubSub
- No changes to the loading page
- No external dependencies

---

## Open Questions

None. All questions resolved during refinement.
