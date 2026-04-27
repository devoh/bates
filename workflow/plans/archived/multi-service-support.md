# Plan: Multi-Service Support

**Goal:** Replace the single-process-per-application model with an
application/service hierarchy where each application manages multiple
services through a single GenServer.

**Proposal:** `workflow/proposals/accepted/2026-04-27-multi-service-support.md`

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-04-27 | Plan created from accepted proposal. |
| 2026-04-27 | Audit: resolved Config return type (tuple list), added routing.md to Phase 7, restructured tests into each phase, clarified Bates.App API surface and pid-to-service mapping. |

## Why This Matters

The spec defines applications as groups of related services, but the
implementation only supports one process per TOML section. A Rails app
that needs a web server, worker, and Vite dev server must be configured
as three unrelated entries. This work introduces the application/service
hierarchy so they can be managed as a unit.

## Acceptance Criteria

- [x] Multi-service TOML config (`[app.services.web]` subtables) is
      parsed into Application structs with multiple services.
- [x] Single-service shorthand (`command` on app table) continues to
      work and is equivalent to one routable service.
- [x] Each application is a single GenServer managing a map of service
      states (pid, ready, log buffer, etc.).
- [x] Starting an application spawns all services concurrently.
- [x] Stopping an application stops all services.
- [x] Application status is derived: all up → up, all down → down,
      any crashed → crashed, otherwise → partial.
- [x] Each routable service (with a `hostname`) gets its own Caddy
      site block.
- [x] `hostname = true` resolves to `<app_name>.test`. A string value
      resolves to `<value>.test`.
- [x] AppRedirect plug resolves arbitrary `.test` hostnames to the
      correct application name via a lookup (not string parsing).
- [x] Dashboard groups services by application. Multi-service apps show
      nested service rows. Single-service apps show only the app row.
- [x] Dashboard controls are application-level. Partial status shows
      Start, Stop, and Restart.
- [x] Loading page starts the full application but redirects when the
      specific requested service is ready (not all services).
- [x] API nests services under applications in the status response.
- [x] Log prefixes: `[myapp]` for single-service, `[myapp:web]` for
      multi-service.
- [x] PubSub broadcasts on `"service:<app>:<service>"` per service and
      `"app:<app>"` for aggregated application status.
- [x] All existing tests updated and passing.
- [x] New tests for multi-service config parsing, lifecycle, dashboard
      grouping, and loading page service-specific redirect.
- [x] Specs updated: `process-management.md`, `control-interface.md`,
      `cli.md`, `routing.md`, `system-overview.md`,
      `sandbox/implementation-notes.md`.
- [x] `Config.applications/0` returns `list({app_name, root, [Service]})`.
- [x] `Bates.App` exposes GenServer calls: `up/1`, `down/1`, `status/1`,
      `services/1`, `service_status/2`.
- [x] `Bates.App` state maps erlexec pids to service names for reliable
      EXIT and stdout/stderr handling.

## Phase 1: Service Struct and Config Parsing

Introduce the Service struct and update Config to parse both formats.
This is the foundation everything else builds on.

### Files

**Create `source/lib/bates/service.ex`**
- Define `Bates.Service` struct with fields: `name`, `command`, `port`,
  `hostname`, `middleware` (default `[]`).
- `hostname` stores the resolved hostname string (e.g., `"myapp.test"`)
  or `nil`.
- `port` stores the assigned port number, or `nil` for portless services.
- This is a data struct only, not a GenServer.

**Rewrite `source/lib/bates/config.ex`**
- Rename `processes/1` to `applications/1`.
- Parse multi-service format: when a TOML table has a `"services"` key,
  iterate its subtables to build Service structs. The `toml` library
  (v0.6.2) parses `[app.services.web]` into nested maps:
  `%{"services" => %{"web" => %{...}}}`.
- Parse single-service shorthand: when a TOML table has a `"command"`
  key, build one Service with `name = app_name`, `hostname = true`
  (resolved to `"#{app_name}.test"`), `port = auto`.
- Resolve `hostname`: TOML boolean `true` → `"#{app_name}.test"`,
  string value → `"#{value}.test"`. The `toml` library parses TOML
  booleans as Elixir booleans, so pattern match on `true` vs binary.
- Assign ports during parsing: auto ports via `PortNumber.next()`,
  fixed ports passed through, `nil` for portless services.
- Return `list({app_name, root, [Service]})` tuples.
  ProcessSupervisor assembles app state from these.

**Create test fixture `source/test/fixtures/multi_service_config.toml`**
- Multi-service app with web (hostname = true), vite (hostname =
  "vite.myapp"), and worker (no hostname, no port).

**Create `source/test/bates/config_test.exs`**
- Test single-service shorthand parsing.
- Test multi-service parsing with hostnames and ports.
- Test hostname resolution (`true` → app name, string → custom).
- Test portless service (no hostname, no port).

## Phase 2: Application GenServer

Replace the Process GenServer with an Application GenServer that manages
multiple services.

### Files

**Create `source/lib/bates/app.ex`**
- Module name: `Bates.App` (avoids collision with `Bates.Application`,
  the OTP Application module).
- GenServer registered in `Bates.ProcessRegistry` by application name.
- State: `%{name, root, services: %{service_name => service_state},
  pids: %{erlexec_pid => service_name}}`.
  Each service state holds: config (Service struct), pid, ready,
  started_at, exit_status, log_buffer, log_count.
  The `pids` map enables reverse lookup from erlexec pid to service
  name for EXIT and stdout/stderr message routing.
- `init/1`: receives `{app_name, root, [Service]}` tuple from
  ProcessSupervisor. Builds initial state with all services down.
- Public API (all GenServer calls):
  - `up/1` — starts all down/crashed services concurrently via
    `:exec.run_link`. Each spawned service enters `starting`. Schedules
    readiness polling per service with a port (use
    `{:check_ready, service_name}` as the message to distinguish
    services). Portless services go straight to `up`. Broadcasts
    per-service status on `"service:#{app}:#{svc}"` and aggregated
    on `"app:#{app}"`.
  - `down/1` — stops all running services. Broadcasts status updates.
  - `status/1` — returns derived application status string.
  - `service_status/2` — returns status for a specific service by name
    (for loading page).
  - `services/1` — returns `list(%{name, hostname, status, port})` for
    API/dashboard.
- Handle `{:EXIT, pid, _}`: look up pid in the `pids` map to find
  which service exited. Update that service's state only.
- Handle `{:check_ready, service_name}`: poll readiness for the named
  service. Each service has its own `started_at` for independent
  timeout tracking.
- Handle `{stream, os_pid, data}` for stdout/stderr: look up os_pid
  in the `pids` map. Tag log with `[app:service]` or `[app]` when
  app name matches service name.

**Delete `source/lib/bates/process.ex`**
- Replaced entirely by `Bates.App`.

**Update `source/lib/bates/process_supervisor.ex`**
- Rename internal references from Process to App.
- `load_processes/0` calls `Config.applications/0` and starts
  `Bates.App` children, passing `{app_name, root, services}` tuples.
- Add `hostname_lookup/0`: returns `%{"myapp.test" => "myapp",
  "vite.myapp.test" => "myapp"}` built by querying all registered
  apps via `Bates.App.services/1`. Called on each request by
  AppRedirect — acceptable cost since Registry.select is fast and
  apps don't change mid-session.
- `app_names/0` replaces `process_names/0`.
- `status/0` returns `%{app_name => app_status}`.

**Create `source/test/bates/app_test.exs`**
- Test single-service app lifecycle (same scenarios as current
  process_readiness_test.exs but using `Bates.App`).
- Test multi-service lifecycle:
  - All services start concurrently on `up/1`.
  - Derived status transitions (down → starting → up, partial, crashed).
  - One service crash doesn't abort others (pid mapping works).
  - `down/1` stops all services.
  - Portless services go to `up` immediately.
  - Readiness timeout on one service → app status `crashed`.
  - Concurrent readiness polls don't interfere (per-service `started_at`).

**Delete `source/test/bates/process_readiness_test.exs`**
- Replaced by `app_test.exs`.

## Phase 3: Caddy Route Generation

Update Caddyfile generation to create one block per routable service.

### Files

**Update `source/lib/bates/caddy.ex`**
- `generate_caddyfile/0`: iterate all applications, then all services
  within each. Generate a site block for each service that has a
  hostname.
- `app_block/3` becomes `service_block/3`: takes hostname (string),
  port, and control_port. Generates `#{hostname} { ... }`.
- Query the Application GenServer for service details (hostname, port)
  instead of querying by process name.

## Phase 4: AppRedirect Plug and Loading Page

Update hostname resolution and the loading page to handle multi-service.

### Files

**Update `source/lib/bates_web/plugs/app_redirect.ex`**
- Replace string parsing with `ProcessSupervisor.hostname_lookup/0`.
- Look up `conn.host` in the hostname map to get the application name.
- If not found and host ends with `.test`, return 404 (unknown app).
- The redirect still goes to `/loading/:app_name`.
- Pass the original hostname through as a query param so the loading
  page knows which service was requested:
  `/loading/myapp?hostname=vite.myapp.test`.

**Update `source/lib/bates_web/live/loading_live.ex`**
- Accept optional `hostname` query param.
- If hostname is provided, look up which service it maps to and
  subscribe to `"service:#{app}:#{service}"`. Otherwise subscribe to
  `"app:#{app}"`.
- Call `App.up(app_name)` to start the full application.
- On service-level subscription: redirect to `https://#{hostname}` when
  that service broadcasts `up`.
- On app-level subscription (no specific hostname): redirect to
  `https://#{app_name}.test` when app status is `up`.

**Update `source/lib/bates_web/router.ex`**
- Update route references from Process to App if needed.
- Routes themselves don't change structurally.

**Update `source/test/bates_web/controllers/fallback_controller_test.exs`**
- Test that `vite.myapp.test` redirects to
  `/loading/myapp?hostname=vite.myapp.test`.
- Test that `myapp.test` redirects to `/loading/myapp` (no hostname
  param).

**Update `source/test/bates_web/live/loading_live_test.exs`**
- Replace `Bates.Process` references with `Bates.App`.
- Add test: loading page with hostname param redirects to that hostname.
- Add test: loading page without hostname param redirects to app
  default.

## Phase 5: Dashboard and API

Update the dashboard to group by application and the API to nest services.

### Files

**Update `source/lib/bates_web/live/dashboard_live.ex`**
- Subscribe to `"app:#{name}"` for each application (not per-process).
- `build_process_list/0` becomes `build_app_list/0`: for each app,
  get derived status, services list, and port info.
- Render app rows with status, controls, and clickable hostname.
- Conditionally render service sub-rows only when app has > 1 service.
- Controls: Start for down/crashed/partial, Stop for starting/up/partial,
  Restart for up/partial.
- Events call `App.up/1`, `App.down/1`.

**Update `source/lib/bates_web/controllers/process_controller.ex`**
- `status/2`: return nested structure with services under each app.
- `start/2` and `stop/2`: call `App.up/1` and `App.down/1`.

**Update `source/test/bates_web/live/dashboard_live_test.exs`**
- Replace `Bates.Process` references with `Bates.App`.
- Add test: multi-service app shows service rows.
- Add test: single-service app shows no service rows.
- Add test: partial status shows correct controls.

## Phase 6: Final Test Pass

Run the full test suite and fix any remaining failures. Tests have been
distributed to earlier phases — this phase is for integration and cleanup.

### Tasks

- Run `mix test` and ensure all tests pass end-to-end.
- Verify `source/test/fixtures/config.toml` still works for
  ProcessSupervisor startup (single-service shorthand).
- Clean up any remaining references to `Bates.Process` across test
  files and source code (`grep -r "Bates.Process" source/`).

## Phase 7: Spec Updates

Update specs to reflect the new API shape and service terminology.

### Files

**Update `specs/control-interface.md`**
- API section: update status response to show nested services.
- Dashboard section: describe application grouping, service sub-rows,
  partial status controls.
- Loading page: describe service-specific redirect behavior.

**Update `specs/routing.md`**
- Route generation section: Caddy generates one site block per routable
  service (any service with a hostname), not per application. Update
  the description and examples.
- Static routes section: each routable service gets its own route with
  fallback, using the service's hostname and port.

**Update `specs/process-management.md`**
- No structural changes needed — the spec already describes the
  application/service model correctly. Minor terminology updates if
  "process" is used where "service" is meant.

**Update `specs/cli.md`**
- Update `bates status` output to show application-level status (the
  CLI operates on applications, not individual services).

**Update `specs/system-overview.md`**
- Update the architecture diagram to show Application GenServer instead
  of Process GenServer.

**Update `specs/sandbox/implementation-notes.md`**
- Update OTP structure section: `Bates.App` replaces `Bates.Process`,
  one GenServer per application managing a services map.
- Update control interface functions: `App.up/1`, `App.down/1`.

## What Does NOT Change

- `source/lib/bates/port_number.ex` — port assignment is already
  per-service-independent.
- `source/lib/bates/application.ex` — OTP Application supervision tree
  structure stays the same.
- `source/lib/bates_web/endpoint.ex` — no changes.
- `source/lib/bates_web/layouts.ex` — no changes.
- `source/lib/bates_web/controllers/error_html.ex` — no changes.
- `source/lib/bates_web/controllers/error_json.ex` — no changes.
- `source/lib/bates_web/controllers/fallback_controller.ex` — no changes.
- `source/test/support/test_server.ex` — still used as-is.
- `source/test/support/test_helpers.ex` — still used as-is.
- `source/test/support/conn_case.ex` — still used as-is.
- Caddy invocation mechanism (stdin piping, restart behavior).
- PubSub infrastructure (Phoenix.PubSub setup).

## Where to Start

> These are pointers from the codebase survey at plan creation time.
> Files may have changed by execution time. Verify before acting.

**Core flow to trace:**
1. `Bates.Config.processes/1` in `source/lib/bates/config.ex` — entry
   point for config parsing. Returns list of `Bates.Process` structs.
2. `Bates.ProcessSupervisor.load_processes/0` in
   `source/lib/bates/process_supervisor.ex` — calls Config, starts
   children.
3. `Bates.Process.init/1` in `source/lib/bates/process.ex` — initializes
   GenServer state, assigns port via `assign_port/1`.
4. `Bates.Process.handle_call(:up, ...)` — spawns OS process via
   `:exec.run_link`, starts readiness polling.
5. `Bates.Caddy.generate_caddyfile/0` in `source/lib/bates/caddy.ex` —
   iterates process names, generates site blocks.
6. `BatesWeb.Plugs.AppRedirect.call/2` — extracts app name from host.
7. `BatesWeb.LoadingLive.mount/3` — subscribes to PubSub, calls
   `Process.up/1`, redirects on up.
8. `BatesWeb.DashboardLive.mount/3` — subscribes to all processes,
   builds flat list.

**Naming collision to avoid:**
- `Bates.Application` (`source/lib/bates/application.ex`) is the OTP
  Application module. The new Application GenServer should be
  `Bates.App` (in `source/lib/bates/app.ex`).

**Test configuration:**
- `source/config/test.exs` sets `poll_interval: 50` and
  `readiness_timeout: 2_000` for fast test feedback.
- `source/test/fixtures/config.toml` has a single-service config used
  by ProcessSupervisor on startup.

**Existing test patterns:**
- Tests use `start_supervised!({Bates.Process, process})` to register
  a process for the test. The new pattern will be
  `start_supervised!({Bates.App, app_config})`.
- `assert_eventually/1` from `test_helpers.ex` polls a function until
  it returns truthy (used for async readiness checks).
- PubSub assertions use `assert_received` for synchronous and
  `assert_receive` with timeout for async state transitions.

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-04-27 | READY FOR AUTONOMOUS EXECUTION | All blocking questions resolved. Config return type decided (tuple list). Routing spec added to Phase 7. Tests restructured into phases. Bates.App API and pid mapping clarified. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

All blocking questions resolved. No missing dependencies, no missing
files, no pre-work required.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| `source/test/fixtures/config.toml` | Ready | Single-service shorthand config. Existing tests use it. |
| `source/test/support/test_server.ex` | Ready | TCP server binding to `$PORT`. Used for readiness tests. |
| `source/test/fixtures/multi_service_config.toml` | To create | Plan Phase 1 creates this. Not a pre-work item. |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| erlexec ~> 2.3 | Installed (2.3.0) | OS process management. Supports linked processes and signal handling. |
| toml ~> 0.6 | Installed (0.6.2) | Parses `[app.services.web]` into nested maps. Booleans parsed as Elixir booleans. |
| phoenix ~> 1.7 | Installed (1.8.5) | LiveView, routing, plug framework. |
| phoenix_live_view ~> 1.0 | Installed (1.1.28) | Query params passed as strings in mount/3 params map. |
| phoenix_pubsub ~> 2.1 | Installed | PubSub infrastructure already in place. |

### Open Questions

| # | Question | Blocking? | Notes |
|---|----------|-----------|-------|
| 1 | Config return type | Resolved | Tuple list: `list({app_name, root, [Service]})`. |
| 2 | hostname_lookup/0 caching | Resolved | Called per request. Acceptable cost — Registry.select is fast. |
| 3 | Bates.App API surface | Resolved | GenServer calls: `up/1`, `down/1`, `status/1`, `services/1`, `service_status/2`. |
| 4 | TOML boolean handling | Resolved | toml v0.6.2 parses booleans as Elixir booleans. Pattern match directly. |
| 5 | EXIT message mapping | Resolved | State includes `pids: %{erlexec_pid => service_name}` reverse map. |
| 6 | Query param format | Resolved | Raw hostname string (e.g., `vite.myapp.test`). |

### POC Gaps

| # | Assumption | Status | Effort |
|---|-----------|--------|--------|
| 1 | Nested TOML parsing works | Verifiable in Phase 1 config tests | Quick |
| 2 | Single GenServer handles multiple linked pids | Verifiable in Phase 2 app tests | Quick |
| 3 | Concurrent readiness polling (per-service timeout) | Verifiable in Phase 2 app tests | Quick |
| 4 | LiveView mount receives query params | Verifiable in Phase 4 loading tests | Quick |

All POC gaps are low-effort and verified by tests written in each phase.

### Pre-Work

None required.

### Blockers

None identified. All referenced files exist. No circular dependencies
between phases. Dependencies are installed and compatible.

## Execution Notes

### Assumptions and Decisions

- `Bates.App` maps both erlexec pids and OS pids in the `pids` map.
  Erlexec delivers EXIT messages using the Erlang pid and stdout/stderr
  using the OS pid, so both mappings are needed for reliable routing.
- `derive_status/1` includes a `"starting"` status (all services
  starting or up) in addition to the four statuses in the proposal.
  This gives the dashboard and loading page a more accurate picture
  during boot.
- `stop_service/4` uses `:exec.kill(pid, :sigkill)` with a 5-second
  monitor timeout. A more graceful SIGTERM-first approach is a future
  improvement.

### Deviations from Plan

- The agent combined all 7 phases into a single commit instead of one
  commit per phase. The spec updates for `cli.md` and `routing.md`
  were added in a follow-up commit.
- `process-management.md` required no changes — it already described
  the multi-service model correctly (it was the target spec the code
  was built from).

### Execution Stats

| Metric | Value |
|--------|-------|
| Commits | 2 |
| Files changed | 22 |
| Lines added | +1164 |
| Lines removed | -570 |
| Tests | 41 pass, 0 failures |
| PR | #7 |
