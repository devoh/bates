# Plan: Core Vertical Slice

**Goal:** Replace the custom DNS/proxy/IPC infrastructure with Caddy
and Phoenix, proving the end-to-end architecture with a single-service
application.

**Proposal:** [Core Vertical Slice](../proposals/accepted/2026-04-23-core-vertical-slice.md)

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-04-23 | Plan created from accepted proposal. |
| 2026-04-23 | Audit: bump Elixir constraint to `~> 1.14` in Phase 1. Clarify Caddy stdin delivery in Phase 5 (shell redirect via temp file). Add Phoenix config details to Phase 3. Add spec reconciliation phase (Phase 7). |
| 2026-04-23 | Phase 1: switch dep from `:exec` 1.0.1 to `:erlexec` 2.3.0. Phase 5: use `send/2` + `:eof` for stdin piping (no temp files). See `experiments/2026-04-23-erlexec-stdin-piping/FINDINGS.md`. |

## Why This Matters

The current infrastructure (custom DNS server, TCP reverse proxy, Unix
socket IPC) needs to be replaced with Caddy + Phoenix before any
higher-level features (multi-service, middleware, dashboard) can be
built. This plan proves the new architecture works end to end.

## Acceptance Criteria

- [ ] `mix deps.get && mix compile` succeeds with Phoenix and LiveView
      dependencies added, `:dns` dependency removed
- [ ] Deleted files: `dns_server.ex`, `proxy.ex`, `request.ex`,
      `http.ex`, `ipc_server.ex`
- [ ] Config field `dir` renamed to `root` in `process.ex` and
      `config.ex`; `env` renamed to `environment`
- [ ] A Caddyfile is generated from the TOML config with one route per
      app using `handle_errors` for fallback, plus a `conjure.test`
      route
- [ ] Caddy starts as a supervised child process with the generated
      config piped to stdin
- [ ] Startup checks for `caddy` in `$PATH`,
      `/etc/resolver/test` existence, and Caddy trust store
- [ ] Phoenix serves on an internal port; Caddy proxies `conjure.test`
      to it
- [ ] Visiting `myapp.test` when the app is down triggers
      `handle_errors` fallback → Phoenix serves a loading page
- [ ] The loading page opens a LiveView WebSocket to `conjure.test`
      with the app name as a param
- [ ] The LiveView subscribes to PubSub for the target app and
      redirects when the app is ready
- [ ] Process GenServer broadcasts state transitions via PubSub
- [ ] JSON API endpoints work: `GET /status`, `POST /processes/:name/start`,
      `POST /processes/:name/stop`
- [ ] An Elixir test app exists in the repo that binds to `$PORT` and
      responds with 200
- [ ] The broken `port_number_test.exs` is fixed
- [ ] README documents manual setup steps (resolver file, Caddy trust)
- [ ] `mix test` passes

## Phases

### Phase 1: Clean up — remove replaced infrastructure

Remove the files and references that Caddy and Phoenix replace. Get
back to a clean, compiling state before adding new code.

**Files to delete:**
- `source/lib/conjure/dns_server.ex`
- `source/lib/conjure/proxy.ex`
- `source/lib/conjure/request.ex`
- `source/lib/conjure/http.ex`
- `source/lib/conjure/ipc_server.ex`

**Files to update:**
- `source/lib/conjure/application.ex` — Remove `Conjure.DNSServer`,
  `Conjure.IPCServer`, and `Conjure.Proxy` from the children list.
  Keep `Registry`, `PortNumber`, and `ProcessSupervisor`.
- `source/mix.exs` — Remove `:dns` dependency. Change `:exec` to
  `:erlexec` (`{:erlexec, "~> 2.3"}` — same API, current package,
  adds `:eof` support for stdin piping). Bump Elixir version
  constraint from `~> 1.11` to `~> 1.14` (required for Phoenix 1.7+;
  Elixir 1.19.5 is installed).
- `source/test/conjure_test.exs` — Remove the placeholder `hello`
  test (the `hello/0` function it tests lives in `conjure.ex` which
  is also placeholder code — remove that too).

**Verify:** `mix compile` succeeds. `mix test` passes (only the port
number test remains, and it has a bug — leave that for Phase 6).

### Phase 2: Config field renames

Update the config format to match the specs: `dir` → `root`,
`env` → `environment`.

**Files to update:**
- `source/lib/conjure/process.ex` — Rename struct fields: `dir` →
  `root`, `env` → `environment`. Update `@enforce_keys` to include
  `:root` instead of `:dir`. Update all references in `handle_call`
  and helper functions (`process.dir` → `process.root`, etc.).
- `source/lib/conjure/config.ex` — No code changes needed (it
  converts TOML keys to atoms dynamically), but any test configs
  should use the new field names.

**Verify:** `mix compile` succeeds. Create a test `config.toml` with
`root` and `environment` fields and confirm it parses correctly.

### Phase 3: Add Phoenix and LiveView

Add Phoenix as a dependency and set up the minimal web infrastructure.
No Caddy yet — Phoenix serves directly for development testing.

**Files to update:**
- `source/mix.exs` — Add `:phoenix`, `:phoenix_live_view`,
  `:phoenix_html`, `:phoenix_pubsub`, `:plug_cowboy`, and
  `:jason` (already present) dependencies.
- `source/lib/conjure/application.ex` — Add Phoenix PubSub and the
  Phoenix Endpoint to the supervision tree.

**Files to create:**
- `source/lib/conjure_web/endpoint.ex` — Phoenix Endpoint
  configuration. Serves on an internal port (e.g., 4080). Includes
  LiveView socket configuration.
- `source/lib/conjure_web/router.ex` — Phoenix Router. Routes:
  - `GET /status` → JSON status endpoint
  - `POST /processes/:name/start` → start endpoint
  - `POST /processes/:name/stop` → stop endpoint
  - `GET /loading/:app_name` → loading page LiveView
  - Fallback route that reads `Host` header, identifies the app, and
    redirects to `/loading/:app_name`
- `source/lib/conjure_web/controllers/process_controller.ex` — JSON
  API controller for status/start/stop.
- `source/lib/conjure_web/live/loading_live.ex` — Loading page
  LiveView. Receives app name as param. Subscribes to PubSub topic
  `process:<app_name>`. On ready state, redirects to the app's URL.
  On crash, displays error and log output.
- `source/lib/conjure_web/layouts/root.html.heex` — Minimal HTML
  layout for LiveView. Configures the LiveSocket JavaScript to
  connect to `conjure.test` (or the current host for development
  without Caddy).
- `source/lib/conjure_web/layouts.ex` — Layout module.
- `source/assets/js/app.js` — LiveView JavaScript client setup.
  Configures `LiveSocket` with the `conjure.test` WebSocket URL.
- `source/config/config.exs` — Phoenix configuration: endpoint URL
  host, PubSub adapter (PG2), JSON library (Jason), LiveView
  `signing_salt` (generate via `mix phx.gen.secret 32` or hardcode a
  random value — this is a local dev tool, not a production app).
- `source/config/dev.exs` — Development-specific config: endpoint
  port (4080), `secret_key_base` (generate a random 64-byte hex
  string), debug logging, code reloader off.

**Verify:** `mix deps.get && mix compile` succeeds. `mix phx.server`
starts and the JSON API responds on `localhost:4080/status`.

### Phase 4: PubSub broadcasting from Process GenServer

Add state transition broadcasts so LiveViews can subscribe to process
events.

**Files to update:**
- `source/lib/conjure/process.ex` — After each state transition
  (up, down, crashed), broadcast via Phoenix PubSub on topic
  `process:<name>`. Broadcast the new status and, on crash, include
  recent log output. Import or alias `Phoenix.PubSub`.

**Verify:** Start an app via `Process.up/1`, observe PubSub messages
with a test subscriber.

### Phase 5: Caddy management

Generate a Caddyfile and manage Caddy as a supervised child process.

**Files to create:**
- `source/lib/conjure/caddy.ex` — GenServer that:
  1. On init, checks for `caddy` binary in `$PATH`.
  2. Checks for `/etc/resolver/test`.
  3. Generates a Caddyfile from `ProcessSupervisor` state: one
     `handle_errors` block per app, plus `conjure.test` routing to
     the Phoenix endpoint port.
  4. Starts Caddy via erlexec with `:stdin` option, sends the
     Caddyfile via `:exec.send/2`, then closes stdin with
     `:exec.send(os_pid, :eof)`. No temp files needed.
     See `experiments/2026-04-23-erlexec-stdin-piping/FINDINGS.md`.
  5. On crash, restarts with a fresh Caddyfile.

**Files to update:**
- `source/lib/conjure/application.ex` — Add `Conjure.Caddy` to the
  supervision tree after `ProcessSupervisor` and the Phoenix Endpoint
  (Caddy needs to know the Phoenix port and the app ports).

**Verify:** Caddy starts and logs indicate it's listening on 443/80.
`curl -k https://conjure.test/status` returns JSON through Caddy.
Visiting an app hostname when the app is down falls back to the
control interface.

### Phase 6: Test app, fix tests, and README

Create the Elixir test app, fix the broken port number test, and
document setup.

**Files to create:**
- `source/test/support/test_server.ex` — A minimal Plug application
  (or raw `:gen_tcp` server) that binds to `$PORT` and responds with
  200 OK. Used for manual end-to-end testing.
- `source/test/fixtures/config.toml` — A test config that points at
  the test server.

**Files to update:**
- `source/test/conjure/port_number_test.exs` — Fix the broken call:
  `Conjure.PortNumber.next_port(daemon)` → `Conjure.PortNumber.next()`.
  The function is module-level, not per-pid.

**Files to create or update:**
- `source/README.md` (or project root `README.md`) — Add a Setup
  section documenting:
  1. Install Caddy via Homebrew (`brew install caddy`)
  2. Create `/etc/resolver/test` (`sudo bash -c 'echo "nameserver
     127.0.0.1" > /etc/resolver/test'`)
  3. Trust Caddy's CA (`caddy trust`)

**Verify:** `mix test` passes. Manual end-to-end test: start Conjure
with the test config, visit `testserver.test` in a browser, observe
the loading page, then the app response.

### Phase 7: Reconcile specs with implementation

Update specs to reflect what was actually built. This is the final
phase before the plan is considered complete.

**Files to review and update:**
- `specs/system-overview.md` — Verify the architecture diagram and
  on-demand flow match the implementation. Update the TOML example
  if field names changed.
- `specs/routing.md` — Verify the Caddyfile pattern and fallback
  mechanism match the implementation.
- `specs/control-interface.md` — Verify the API endpoints, loading
  page behavior, and PubSub topics match the implementation.
- `specs/process-management.md` — Verify struct fields (`root`,
  `environment`) and state transitions match the implementation.
- `specs/sandbox/implementation-notes.md` — Update Caddy invocation
  details (shell redirect approach), add any new implementation
  decisions made during execution.

**Verify:** Read each spec and confirm it accurately describes the
current implementation. No stale references to removed infrastructure.

## What Does NOT Change

- Process GenServer lifecycle logic (up/down/crashed states,
  erlexec usage, signal handling)
- ProcessSupervisor structure (DynamicSupervisor, Registry)
- PortNumber allocation (monotonic from 4200)
- `$PORT` substitution in commands
- Single-service config format
- No multi-service, no middleware, no `hostname` field
- No dashboard (only loading page)
- No CLI
- No `conjure setup` command
- Config file read from current directory

## Where to Start

> These are pointers from the codebase survey at plan creation time.
> Files may have changed by execution time. Verify before acting.

**Core flow to trace:**
- `Application.start/2` → children list → supervision tree
- `ProcessSupervisor.start_link/1` → `load_processes/0` →
  `Config.processes/1` → `Process.start_link/1`
- `Process.init/1` → `assign_port/1` → state with `pid: nil`
- `Process.handle_call(:up, ...)` → `:exec.run_link/2` → OS process

**Files that should NOT change (verify after):**
- `source/lib/conjure/port_number.ex` — keeps monotonic allocation
- `source/lib/conjure/process_supervisor.ex` — keeps DynamicSupervisor
  structure (may need minor additions for port lookups by Caddy
  generator, but core structure stays)

**Existing test files:**
- `source/test/conjure/port_number_test.exs` — fix broken function
  call
- `source/test/conjure_test.exs` — delete (tests placeholder code)
- `source/test/test_helper.exs` — keep as-is

**Key implementation notes (from sandbox):**
- Caddyfile uses `handle_errors` not `handle_response` for fallback
- LiveView WebSocket connects to `conjure.test`, app name as param
- Caddy invocation: `caddy run --adapter caddyfile -c -`
- Caddy stdin delivery: shell redirect from temp file (see experiment)
- See `specs/sandbox/implementation-notes.md` for details

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-04-23 17:00 CDT | READY FOR AUTONOMOUS EXECUTION | All blockers resolved: Elixir version constraint updated in plan, erlexec stdin piping verified via experiment, Phoenix config details added. |
| 2026-04-23 17:15 CDT | READY FOR AUTONOMOUS EXECUTION | Re-audited stdin piping: `:erlexec` 2.3.0 supports `send/eof` natively. No temp files needed. Updated Phase 1 (dep change) and Phase 5 (stdin delivery). |

### Verdict: READY FOR AUTONOMOUS EXECUTION

All blockers resolved. The plan can be executed autonomously via
`/execute-plan`.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| TOML config format | Ready | Existing `config.ex` handles TOML parsing; field renames covered in Phase 2 |
| Test config fixture | Not yet created | Created during Phase 6; straightforward |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| Elixir ~> 1.14 | Installed (1.19.5) | Plan updated to bump constraint in Phase 1 |
| Erlang/OTP | Installed (27) | Compatible with Phoenix 1.7+ |
| Phoenix + LiveView | Not installed | Added in Phase 3 via `mix deps.get` |
| Caddy | Installed (v2.9.1) | In `$PATH` via Homebrew |
| erlexec | Upgrade needed | Switch from `:exec` 1.0.1 to `:erlexec` 2.3.0 in Phase 1. Same API, adds `:eof` support |
| `/etc/resolver/test` | Prerequisite | Runtime check in Phase 5; documented in Phase 6 README |

### Open Questions

| # | Question | Blocking? | Notes |
|---|----------|-----------|-------|
| 1 | Caddy stdin delivery mechanism | No | Resolved. Shell redirect from temp file works. See `experiments/2026-04-23-erlexec-stdin-piping/FINDINGS.md` |
| 2 | Phoenix endpoint port | No | Resolved. Use 4080 as internal port, configured in `config/dev.exs` |
| 3 | LiveView signing_salt / secret_key_base | No | Resolved. Generate random values; this is a local dev tool, not production |

### POC Gaps

| # | Assumption | Experiment | Result |
|---|-----------|------------|--------|
| 1 | erlexec can pipe stdin to Caddy | Tested `:exec` 1.0.1 (no `:eof` support) and `:erlexec` 2.3.0 (`send/eof` works) | Confirmed. Native stdin piping, no temp files. See `experiments/2026-04-23-erlexec-stdin-piping/FINDINGS.md` |

### Pre-Work

None required. All prerequisites are either installed or handled
within the plan phases.

### Blockers

None identified. All original blockers resolved.
