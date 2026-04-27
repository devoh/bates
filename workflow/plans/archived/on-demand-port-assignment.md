# Plan: On-Demand Port Assignment

**Goal:** Move port assignment from config parsing to app startup and
use Caddy's admin API for dynamic route upstream updates.

**Proposal:** [On-Demand Port Assignment](../proposals/accepted/2026-04-27-on-demand-port-assignment.md)

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-04-27 | Plan created from accepted proposal. |
| 2026-04-27 | Audit: added `parse_command` changes to Phase 2, added `system-overview.md` to Phase 6, added Caddy POC step to Phase 3. Resolved Caddy failure handling. |
| 2026-04-27 | Simplified `parse_command`: remove `$PORT` regex substitution entirely, let shell expand env var. Aligns with future middleware design (#5). |

## Why This Matters

Ports are assigned during config parsing even for apps that never
start. This couples a runtime concern to the configuration layer.
Moving port assignment to `App.up/1` and using Caddy's admin API
for dynamic upstream updates makes configuration pure and routes
reflect actual runtime state.

## Acceptance Criteria

- [x] `Config.applications/1` returns services with `port: nil`
      for auto-assigned services (no `PortNumber.next()` calls)
- [x] `Config.applications/1` returns services with the declared
      integer for explicit `port = 8080` services
- [x] `App.up/1` assigns a port to each routable service via
      `PortNumber.next()` (or uses the declared port for static ones)
- [x] Assigned port is stored in `assigned_port` field in GenServer
      service state, separate from `config.port`
- [x] `App.down/1` releases the assigned port (`assigned_port: nil`)
- [x] `App.services/1` returns the `assigned_port` value (nil when
      stopped, integer when running)
- [x] `env_with_port` and `check_ready` read from `assigned_port`
- [x] `parse_command` no longer does `$PORT` regex substitution;
      `$PORT` is expanded by the shell from the `PORT` env var
- [x] Caddy starts with a static config where every routable service
      route points to the control interface
- [x] Caddy config includes a `*.test` catch-all route pointing to
      the control interface
- [x] Each route has a stable `@id` tag for targeted API updates
- [x] Caddy admin API listens on TCP `localhost:2019` (unix socket
      assumption unverified; TCP fallback used per plan)
- [x] `Caddy.update_route/2` updates a route's upstream to the
      assigned port via the admin API
- [x] `Caddy.revert_route/1` reverts a route's upstream to the
      control interface via the admin API
- [x] `App.up/1` calls `Caddy.update_route/2` synchronously after
      port assignment
- [x] `App.down/1` calls `Caddy.revert_route/1` synchronously after
      stopping services
- [x] On Caddy crash recovery, routes for running apps are
      re-registered
- [x] Dashboard shows port as nil for stopped apps, integer for
      running apps
- [x] Specs updated: `process-management.md` port assignment section,
      `routing.md` static routes section, `system-overview.md`
      on-demand startup flow and ports table
- [x] Existing tests updated, new Caddy-related tests added
- [x] `mix test` passes

## Phases

### Phase 1: Remove port assignment from Config

Remove `PortNumber.next()` calls from `Config`. Auto-assigned
services get `port: nil`. Static-port services keep their declared
integer. The `resolve_port` function simplifies to just returning
the declared value or nil.

**Files to update:**
- `source/lib/bates/config.ex` — In `build_single_service/2`,
  change `port: Bates.PortNumber.next()` to `port: nil`. In
  `resolve_port/2`, remove the `PortNumber.next()` call — return
  `nil` for auto-assigned services, the integer for explicit ones.

**Files to update (tests):**
- `source/test/bates/config_test.exs` — The "parses single-service
  shorthand" test asserts `is_integer(service.port)` — change to
  `assert service.port == nil`. The "parses multi-service config"
  test asserts `is_integer(web.port)` and `is_integer(vite.port)` —
  change both to `assert web.port == nil` / `assert vite.port == nil`.

**Verify:** `mix test test/bates/config_test.exs` passes. Config
returns `nil` ports for auto-assigned services.

### Phase 2: Add `assigned_port` to App GenServer

Add port assignment to `App.up/1` and port release to `App.down/1`.
Add `assigned_port` field to service state. Update all code that
reads `config.port` for runtime purposes to read `assigned_port`.

**Files to update:**
- `source/lib/bates/app.ex`:
  - In `init/1`, add `assigned_port: nil` to the service state map.
  - In `start_service/3`, before spawning the OS process: if
    `config.port` is an integer, set `assigned_port` to that value;
    if `config.port` is nil and `config.hostname` is set, call
    `PortNumber.next()` and set `assigned_port`; if neither, leave
    `assigned_port` as nil.
  - Remove the `$PORT` regex substitution from `parse_command/1`.
    The `PORT` env var (set by `env_with_port`) is already available
    to the shell, so `$PORT` in commands like `bin/server -p $PORT`
    is expanded by the shell naturally. `parse_command` simplifies
    to just converting the command string to a charlist. Remove
    the `@port_regex` module attribute.
  - Update `env_with_port/1` to take `assigned_port` instead of the
    Service struct. Return `[]` when nil, `[{~c"PORT", ...}]` when
    set.
  - Update `check_ready` handler to read `svc.assigned_port` instead
    of `config.port` for the TCP connect and timeout message.
  - Update `start_service/3` to use `assigned_port` for the
    `config.port == nil` readiness check (portless services).
  - In `stop_service/3`, reset `assigned_port: nil`.
  - In `handle_call(:services, ...)`, return `assigned_port` instead
    of `config.port` in the service map.

**Files to update (tests):**
- `source/test/bates/app_test.exs` — Tests currently pass ports via
  `PortNumber.next()` in the Service struct. Change routable services
  to use `port: nil` (auto-assign) and verify that `App.services/1`
  returns the assigned port after `up/1` and nil after `down/1`. The
  `single_service_config` helper needs updating: remove the explicit
  port, use `port: nil` with `hostname: "testapp.test"`. Tests that
  need a specific port for assertions can check the value returned
  by `App.services/1` after starting.

**Verify:** `mix test test/bates/app_test.exs` passes. Services get
ports on start, lose them on stop.

### Phase 3: Caddy admin API and initial config

Rewrite the Caddy GenServer to start with a JSON config (generated
from service hostnames, all pointing to control interface) and
expose `update_route/2` and `revert_route/1` functions that use the
admin API over a unix socket.

**Before implementing**, validate these assumptions:
1. Caddy accepts JSON config via `caddy run --config - --adapter` (no
   adapter flag needed for native JSON).
2. Caddy's JSON config supports `@id` tags on config objects for
   targeted admin API updates.
3. HTTP requests to Caddy's admin API over a unix socket work from
   Erlang (using `:gen_tcp` with `{:local, path}` for the socket).
If any assumption fails, fall back to: start with JSON config via
temp file, use full config reload via `POST /load` over TCP
`localhost:2019` instead of targeted updates over unix socket.

**Files to update:**
- `source/lib/bates/caddy.ex`:
  - Change the startup command from Caddyfile-based to JSON config.
    Caddy can be started with `caddy run --config -` and JSON piped
    to stdin, or with `--config <path>` pointing to a temp file.
  - Add `admin` config to specify the unix socket address (e.g.,
    `unix//tmp/bates-caddy.sock`).
  - Replace `generate_caddyfile/0` with a function that builds the
    Caddy JSON config. Each routable service gets a server block
    with an `@id` tag (e.g., `"route:<hostname>"`) pointing to the
    control interface. Include a `*.test` catch-all server.
  - Add `update_route(hostname, port)` — makes an HTTP request to
    the admin API via the unix socket to update the route identified
    by `@id` with the new upstream and `handle_errors` fallback.
  - Add `revert_route(hostname)` — reverts the route to point at
    the control interface only (removes `handle_errors`, sets
    upstream to control interface).
  - Update crash recovery (`handle_info({:DOWN, ...})`) to
    regenerate the initial config and re-register routes for running
    apps by querying `ProcessSupervisor`.

- `source/config/config.exs` or `source/config/dev.exs` — May need
  to add a config entry for the Caddy socket path if it should be
  configurable. Otherwise, use a module attribute.

**Files to create:**
- `source/test/bates/caddy_test.exs` — Test the Caddy module's
  config generation: verify the JSON structure includes all routable
  services, the catch-all, `@id` tags, and the admin socket config.
  Testing the actual admin API calls requires a running Caddy
  instance, so these may need to be integration tests or use mocks
  for the HTTP client.

**Verify:** `mix compile` succeeds. Caddy starts with the JSON
config and serves all routes via the control interface.

### Phase 4: Wire App to Caddy

Connect `App.up/1` and `App.down/1` to the Caddy module so route
upstreams are updated on start and reverted on stop.

**Files to update:**
- `source/lib/bates/app.ex`:
  - In `start_service/3`, after assigning the port and before
    broadcasting "starting": call `Caddy.update_route(hostname, port)`
    synchronously for services that have a hostname. If the call
    fails, log a warning and continue — the app starts but is not
    routable until Caddy recovers. On Caddy crash recovery, routes
    for running apps are re-registered.
  - In `stop_service/3`, after stopping the OS process and before
    broadcasting "down": call `Caddy.revert_route(hostname)` for
    services that have a hostname. If the call fails, log and
    continue.

**Verify:** Start an app, confirm the Caddy route points to the
assigned port. Stop the app, confirm the route reverts. `mix test`
passes.

### Phase 5: Update tests

Ensure all existing tests pass with the new flow and add targeted
tests for the integration between App and Caddy.

**Files to update:**
- `source/test/bates/app_test.exs` — Verify that after `up/1`,
  services have an `assigned_port` and after `down/1` they don't.
  The "transitions to up when port is listening" test should still
  work since the test server binds to `$PORT`.
- `source/test/bates_web/controllers/process_controller_test.exs` —
  Verify the API returns port as nil for stopped apps.
- `source/test/bates_web/live/loading_live_test.exs` — May need
  updates if tests construct Service structs with explicit ports.

**Verify:** `mix test` — all tests green.

### Phase 6: Update specs

Update the specs to reflect the new port assignment timing and
dynamic routing behavior.

**Files to update:**
- `specs/process-management.md` — Rewrite the "Port Assignment"
  section: ports are now assigned in `App.up/1`, not at init time.
  Auto-assigned ports use `PortNumber.next()` at start time.
  Static ports use the declared value. Ports are released on stop.
  Remove the statement about ports being stable across stop/start
  cycles.
- `specs/routing.md` — Rewrite "Static Routes with Fallback":
  routes are now defined at startup pointing to the control
  interface, with upstreams updated dynamically via the admin API
  when apps start. Add the catch-all route. Update "How It
  Connects" to note that starting/stopping services does update
  Caddy configuration via the admin API.
- `specs/system-overview.md` — Update the "on-demand startup flow"
  (lines 79-90) to note that ports are assigned at `App.up/1` time,
  not init time. Update "Caddy Lifecycle" references if present.
  Update the Ports table if it references static port assignment.

**Verify:** Read each updated spec and confirm it accurately
describes the implemented behavior.

## What Does NOT Change

- Service struct fields (config still has `port`, `hostname`, etc.)
- AppRedirect plug (hostname lookup is hostname-based, not port-based)
- Dashboard template (reads from `App.services/1` which now returns
  `assigned_port` — the template just displays whatever port value
  it gets, including nil)
- Loading page
- ProcessSupervisor
- CLI/API endpoint routes

## Where to Start

> These are pointers from the codebase survey at plan creation time.
> Files may have changed by execution time. Verify before acting.

**Core flow to trace:**
- `Config.build_single_service/2` at line 29 and `resolve_port/2`
  at line 57 — where ports are currently assigned. This is the
  removal point.
- `App.handle_call(:up, ...)` at line 70 → `start_service/3` at
  line 220 — where services are spawned. Port assignment and Caddy
  notification go here.
- `App.handle_call(:down, ...)` at line 84 → `stop_service/3` at
  line 259 — where services are stopped. Port release and Caddy
  revert go here.
- `App.handle_call(:services, ...)` at line 111 — returns
  `svc.config.port` on line 118. Change to `assigned_port`.
- `App.handle_info(:check_ready, ...)` at line 126 — reads
  `config.port` on lines 129 and 144. Change to `assigned_port`.
- `env_with_port/1` at line 320 — reads `%Service{port: ...}`.
  Change to accept `assigned_port` value directly.
- `parse_command/1` at line 337 — does `$PORT` regex substitution.
  Remove the substitution; simplify to `to_charlist(command)`. The
  shell expands `$PORT` from the `PORT` env var set by `env_with_port`.
  Also remove `@port_regex` at line 11.

**Caddy module:**
- `Caddy.start_caddy/0` at line 72 — where Caddy is launched.
  Rewrite to use JSON config instead of Caddyfile.
- `Caddy.generate_caddyfile/0` at line 87 — replace with JSON
  config generation including `@id` tags.
- `Caddy.service_block/3` at line 110 — the per-service route
  template. Replace with JSON equivalent.

**Existing test files:**
- `test/bates/config_test.exs` — 7 tests, port assertions need
  updating
- `test/bates/app_test.exs` — 10 tests, port setup in helpers
  needs updating
- `test/bates_web/controllers/process_controller_test.exs` — 2
  tests, may need port assertion updates
- `test/bates_web/controllers/fallback_controller_test.exs` — 5
  tests, constructs Service structs with `PortNumber.next()` — these
  should still work since config ports can be integers
- `test/bates_web/live/loading_live_test.exs` — constructs Service
  structs with ports, may need updates

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-04-27 | READY FOR AUTONOMOUS EXECUTION | Added `parse_command` deferral, Caddy POC fallback strategy, `system-overview.md` to Phase 6. Resolved Caddy failure handling question. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

All blocking questions resolved. Caddy admin API assumptions have a
documented fallback strategy if they don't hold. The plan can be
executed autonomously via `/execute-plan`.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| Test fixtures | Ready | `config.toml` and `multi_service_config.toml` exist, no hardcoded ports |
| Test server | Ready | `test_server.ex` binds to `$PORT`, works with dynamic assignment |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `:gen_tcp` | Available | Already used in PortNumber and App readiness check |
| `:exec` (erlexec) | Installed | Used by App and Caddy GenServers |
| HTTP client for admin API | Available | `:httpc` (stdlib) or raw `:gen_tcp` for unix socket |
| Caddy binary | Runtime | Not a mix dep; launched via `:exec`. Must be in `$PATH` |

### Open Questions

| # | Question | Blocking? | Notes |
|---|----------|-----------|-------|
| 1 | Caddy failure on `up/1` | Resolved | Start anyway, log warning. Decided during audit. |

### POC Gaps

| # | Assumption | Status | Notes |
|---|-----------|--------|-------|
| 1 | Caddy JSON config supports `@id` tags | Unverified | Fallback: full config reload via `POST /load` if targeted updates don't work |
| 2 | Caddy accepts JSON via `--config -` stdin | Unverified | Fallback: write to temp file, use `--config <path>` |
| 3 | Unix socket admin API works from Erlang | Unverified | Fallback: TCP `localhost:2019` instead of unix socket |
| 4 | `parse_command` with deferred ports | Resolved | Removed `$PORT` substitution entirely. Shell expands env var. Aligns with middleware spec (#5). |

All POC gaps have documented fallback strategies. The execution
agent can validate and pivot during Phase 3 without blocking.

### Pre-Work

None required. All fallback strategies are self-contained within
the plan phases.

### Blockers

None identified.

## Execution Notes

### Deviations from Plan

- **Caddy admin API uses TCP `localhost:2019` instead of unix socket.**
  POC gap #3 (unix socket from Erlang) was unverified. The agent used
  the documented fallback: TCP on the default Caddy admin port. This is
  simpler and avoids socket path management.

- **Caddy JSON config via `--config -` stdin worked.** POC gap #2
  confirmed during execution.

- **`@id` tags work for targeted admin API updates.** POC gap #1
  confirmed. Routes use `PATCH /id/<route_id>` for targeted updates.

- **Used `:httpc` (OTP stdlib) for admin API calls.** No external HTTP
  dependency needed. Added `:inets` to `extra_applications` in `mix.exs`.

### Execution Stats

| Metric | Value |
|--------|-------|
| Duration | ~11m |
| Commits | 6 |
| Files changed | 13 |
| Tests | 52 (all passing) |
| Tests added | 8 (caddy_test.exs) |
