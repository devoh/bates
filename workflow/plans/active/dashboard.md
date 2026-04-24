# Plan: Dashboard

**Goal:** Add a LiveView dashboard at `conjure.test` showing all
configured applications with real-time status and start/stop/restart
controls.

**Proposal:** [Dashboard](../proposals/accepted/2026-04-24-dashboard.md)

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-04-24 | Plan created from accepted proposal. |
| 2026-04-24 | Audit: add `specs/routing.md` to Phase 4, add PubSub dispatch note to Phase 2, add acceptance criterion for routing spec. |

## Why This Matters

Visiting `conjure.test` returns a 404. There's no browser-based way to
see which applications are configured, what state they're in, or
control them. The dashboard fills this gap with real-time visibility
and one-click controls.

## Acceptance Criteria

- [ ] Visiting `conjure.test/` in a browser shows the dashboard
- [ ] The dashboard lists all configured processes with name, hostname
      (clickable link), status, and port
- [ ] Status updates in real time via PubSub (no page refresh)
- [ ] All four lifecycle states displayed: down, starting, up, crashed
- [ ] Start button for down/crashed processes
- [ ] Stop button for starting/up processes
- [ ] Restart button for up processes
- [ ] Controls update immediately when status changes
- [ ] Empty state shows "No applications configured" when no processes
      exist
- [ ] App-domain requests (e.g., `myapp.test/`) redirect to
      `/loading/<name>` via a plug, not the dashboard
- [ ] FallbackController simplified (host check moved to plug)
- [ ] Existing tests updated, new dashboard tests added
- [ ] Existing fallback controller tests updated for plug changes
- [ ] Specs updated: `control-interface.md`, `system-overview.md`,
      `routing.md`
- [ ] `mix test` passes

## Phases

### Phase 1: App-domain redirect plug

Extract the host check from FallbackController into a plug in the
browser pipeline. This must happen first because the dashboard route
would otherwise catch app-domain requests.

**Files to create:**
- `source/lib/conjure_web/plugs/app_redirect.ex` — A plug module
  that compares `conn.host` against the control hostname
  (`ConjureWeb.Endpoint.config(:url)[:host]`). If the host is not
  the control host, extract the app name (strip `.test` suffix) and
  redirect to `/loading/<app_name>`. Otherwise, pass through.

**Files to update:**
- `source/lib/conjure_web/router.ex` — Add the plug to the browser
  pipeline: `plug ConjureWeb.Plugs.AppRedirect`.
- `source/lib/conjure_web/controllers/fallback_controller.ex` —
  Remove the host check. The controller no longer needs to
  distinguish app domains from the control domain. It only handles
  `conjure.test` requests now, so it can always return 404.

**Files to update (tests):**
- `source/test/conjure_web/controllers/fallback_controller_test.exs` —
  The "redirects app domain to loading page" test now tests the plug
  behavior (the redirect still happens, just earlier in the pipeline).
  The "returns 404 on control domain" test should still pass.

**Verify:** `mix test` passes. App-domain requests redirect to
`/loading/<name>`. Control-domain requests pass through to routes.

### Phase 2: Dashboard LiveView

Create the dashboard LiveView with real-time status display and
process controls.

**Files to create:**
- `source/lib/conjure_web/live/dashboard_live.ex` — A LiveView that:
  - In `mount/3`: calls `ProcessSupervisor.process_names/0`, then
    `Process.status/1` and `Process.port/1` for each name.
    Subscribes to `process:<name>` PubSub topic for each. Stores
    a list of process maps in assigns.
  - Handles `{:status, ...}` broadcasts in `handle_info/2`. Since
    the broadcast messages don't include the process name, the
    simplest approach is to re-query all process statuses on any
    status message. This is fast for a local tool with a handful
    of processes.
  - `handle_event("start", %{"name" => name}, socket)` — calls
    `Process.up/1`.
  - `handle_event("stop", %{"name" => name}, socket)` — calls
    `Process.down/1`.
  - `handle_event("restart", %{"name" => name}, socket)` — calls
    `Process.down/1` then `Process.up/1`.
  - `render/1` shows a table/list of processes. Each row has: name,
    hostname (link to `https://<name>.test`), status, port, and
    contextual controls based on status:
    - down → Start
    - starting → Stop
    - up → Stop, Restart
    - crashed → Start
  - Empty state: "No applications configured" when the process list
    is empty.
  - Inline styles matching the loading page aesthetic (system-ui
    font, clean layout, no CSS framework).

**Files to update:**
- `source/lib/conjure_web/router.ex` — Add
  `live "/", DashboardLive` to the browser scope, before the
  loading and catch-all routes.

**Verify:** `mix compile` succeeds. Visiting `conjure.test/` shows the
dashboard with process list.

### Phase 3: Tests

Add tests for the dashboard LiveView and update existing tests as
needed.

**Files to create:**
- `source/test/conjure_web/live/dashboard_live_test.exs` — Tests:
  - Dashboard renders with process list (name, hostname, status,
    port)
  - Dashboard shows empty state when no processes configured
  - Status updates via PubSub (send a broadcast, assert the view
    updates)
  - Start button calls `Process.up/1` (for a down process)
  - Stop button calls `Process.down/1` (for an up process)
  - Restart calls `Process.down/1` then `Process.up/1`

**Files to update:**
- `source/test/conjure_web/controllers/fallback_controller_test.exs` —
  Update if the plug changes affect test behavior. The app-domain
  redirect test should still pass (the redirect happens in the plug
  now). The 404 test on control domain for `"/"` path may need
  updating since `"/"` now routes to the dashboard, not the
  fallback controller. Test 404 on a non-root path instead.

**Verify:** `mix test` passes. All existing and new tests green.

### Phase 4: Update specs

Update specs to reflect the dashboard implementation.

**Files to update:**
- `specs/control-interface.md` — Update the Dashboard section's
  "What It Shows" to include "starting" as a fourth status. Note
  the app-domain redirect plug in routing context.
- `specs/system-overview.md` — If the overview references the
  control interface, verify the dashboard description is accurate.
- `specs/routing.md` — Update to document the app-domain redirect
  plug. The spec currently describes app-domain handling via the
  FallbackController; update to reflect that the plug intercepts
  app-domain requests before they reach routes.

**Verify:** Read each updated spec and confirm it accurately
describes the implemented behavior.

## What Does NOT Change

- Process GenServer (no new API, no behavior changes)
- ProcessSupervisor (no changes)
- PubSub topics or message formats
- Loading page
- API endpoints
- Caddy configuration
- PortNumber module

## Where to Start

> These are pointers from the codebase survey at plan creation time.
> Files may have changed by execution time. Verify before acting.

**Core flow to trace:**
- `FallbackController.index/2` — current host check logic that moves
  to the plug.
- `ProcessSupervisor.process_names/0` — returns all registered names
  from the Registry. This is the data source for the dashboard.
- `Process.status/1`, `Process.port/1` — per-process queries for
  building the initial dashboard state.
- `LoadingLive.mount/3` — example of PubSub subscription pattern in
  a LiveView. The dashboard follows the same pattern but for all
  processes.

**Router structure:**
- API routes are in their own scope with `:api` pipeline (lines 16-22).
- Browser routes are in a separate scope with `:browser` pipeline
  (lines 24-29). The dashboard route goes here, before the catch-all.

**Endpoint config:**
- `ConjureWeb.Endpoint.config(:url)[:host]` returns the control
  hostname (e.g., `"conjure.test"`). Used by FallbackController and
  will be used by the new plug.

**Existing test files:**
- `test/conjure_web/live/loading_live_test.exs` — LiveView test
  patterns (PubSub subscription, redirect assertions)
- `test/conjure_web/controllers/fallback_controller_test.exs` — 2
  tests, both may need updating
- `test/support/conn_case.ex` — test helper with `@endpoint` and
  `build_conn()`

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-04-24 | READY FOR AUTONOMOUS EXECUTION | No blockers. Added `specs/routing.md` to Phase 4, clarified PubSub dispatch approach in Phase 2. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

All dependencies are in place, no open questions remain, and no
pre-work is required.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| Test helper (conn_case.ex) | Ready | Exists with LiveView test support |
| Test server fixture | Ready | `test/support/test_server.ex` exists for process readiness tests |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `ProcessSupervisor.process_names/0` | Verified | Returns registered names from Registry |
| `Process.up/1`, `down/1`, `port/1`, `status/1` | Verified | All exist with expected signatures |
| Phoenix PubSub | Verified | In supervision tree as `Conjure.PubSub` |
| Phoenix LiveView | Verified | In mix.exs deps |
| `ConjureWeb.Endpoint.config(:url)[:host]` | Verified | Returns `"conjure.test"` |

### Open Questions

None.

### POC Gaps

| # | Assumption | Status | Notes |
|---|-----------|--------|-------|
| 1 | Re-querying all statuses on PubSub message is fast enough | Trivially verifiable | GenServer calls are microseconds for local processes; fine at dev-tool scale |
| 2 | `Process.port/1` works before `up/1` is called | Trivially verifiable | Port is assigned at init time, not at startup |

### Pre-Work

None required.

### Blockers

None identified.
