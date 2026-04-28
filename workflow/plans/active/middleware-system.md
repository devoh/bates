# Plan: Middleware System

**Goal:** Replace the hard-coded `PORT` special case in `App.start_service/3`
with a middleware pipeline that transforms each service's configuration into
a process invocation (prologue commands + environment + command) at init
time.

**Proposal:** `workflow/proposals/accepted/2026-04-28-middleware-system.md`

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-04-28 | Plan created from accepted proposal. |
| 2026-04-28 | Audit: confirmed exec/env/TOML POC gaps. Resolved ProcessSupervisor error handling (raise on Config error). Phase 2 updated. |

## Why This Matters

Today, `PORT` assignment is wired directly into `App.start_service/3` via
`env_with_port/1` and `parse_command/1`. There is no way to add other
environment variables or run shell setup (like sourcing asdf) before the
service command. Applications that depend on a runtime version manager
can't be brought up through Bates without the user pre-baking a fragile
shell command.

The spec already describes a middleware pipeline with a process invocation
model. This plan implements it.

## Acceptance Criteria

- [ ] `Bates.ProcessInvocation` struct exists with `prologue` (list of
      strings), `environment` (map of string-to-string), and `command`
      (string) fields.
- [ ] `Bates.Middleware` behaviour declares
      `apply(invocation, context) :: invocation`.
- [ ] `Bates.Middleware.Asdf` appends
      `source $(brew --prefix)/opt/asdf/libexec/asdf.sh` to `prologue`.
- [ ] `Bates.Middleware.Port` adds `"PORT" => "<assigned_port>"` to
      `environment`. The middleware is auto-injected by `Config` for any
      service whose hostname is non-nil (i.e. any service that gets a
      port assignment). Users do not have to list it.
- [ ] `Config.applications/0` parses an optional `middleware` key on the
      application table and on each service table, concatenates the two
      lists (app-level first), and appends `"port"` for services with a
      hostname. The merged list is stored on the `Service` struct.
- [ ] Single-service shorthand parses `middleware` from the application
      table.
- [ ] Unknown middleware names cause `Config.applications/0` to return
      `{:error, {:unknown_middleware, name}}`.
- [ ] `App.start_service/3` builds a `ProcessInvocation` by folding the
      service's middleware list over an empty invocation seeded with the
      service's command, compiles the prologue and command into a single
      shell string of the form `prologue1; prologue2; exec <command>`,
      passes the environment map via erlexec's `env` option, and runs the
      compiled string through `:exec.run_link/2`.
- [ ] Signals reach the spawned service directly (verified by the `exec`
      prefix on the command).
- [ ] `env_with_port/1` and `parse_command/1` are removed from
      `Bates.App`.
- [ ] All existing tests pass.
- [ ] New unit tests cover each built-in middleware's transform.
- [ ] New integration test exercises a service whose middleware injects
      a prologue command and an env var, and verifies both are visible
      to the running process.
- [ ] `specs/process-management.md` reflects the implemented behaviour
      (implicit `port` middleware, parse-time merge, env via erlexec,
      `exec` prefix, parse-time validation).

## Phase 1: Process Invocation and Middleware Plumbing

Introduce the data structures and behaviour. No callers yet.

### Files

**Create `source/lib/bates/process_invocation.ex`**

- Define `Bates.ProcessInvocation` struct:
  - `prologue: [String.t()]`, default `[]`
  - `environment: %{String.t() => String.t()}`, default `%{}`
  - `command: String.t()`, required
- Add `compile/1`: returns the shell string
  `"<prologue1>; <prologue2>; exec <command>"`. When `prologue` is empty,
  the result is `"exec <command>"`.

**Create `source/lib/bates/middleware.ex`**

- Define `Bates.Middleware` behaviour:
  - `@callback apply(ProcessInvocation.t(), map()) :: ProcessInvocation.t()`
- Add `Bates.Middleware.Registry` (in the same file, or a sibling module):
  - `lookup/1`: takes a string name, returns `{:ok, module}` or
    `{:error, :unknown}`. Backed by a private map literal, e.g.
    `%{"asdf" => Bates.Middleware.Asdf, "port" => Bates.Middleware.Port}`.
- Add `apply_pipeline/3`: takes a `ProcessInvocation`, a list of module
  atoms (already resolved from names), and a context map. Folds over the
  modules, calling each one's `apply/2`.

**Create `source/lib/bates/middleware/asdf.ex`**

- `@behaviour Bates.Middleware`
- `apply(invocation, _context)`: appends
  `"source $(brew --prefix)/opt/asdf/libexec/asdf.sh"` to
  `invocation.prologue`.

**Create `source/lib/bates/middleware/port.ex`**

- `@behaviour Bates.Middleware`
- `apply(invocation, %{assigned_port: port})` when `is_integer(port)`:
  `put_in invocation.environment["PORT"], to_string(port)`.
- `apply(invocation, _)`: returns the invocation unchanged. (Defensive —
  shouldn't be reached because Config only injects `port` for services
  with a hostname, but guards against future config drift.)

### Tests

**Create `source/test/bates/process_invocation_test.exs`**

- `compile/1` returns `"exec <command>"` when prologue is empty.
- `compile/1` joins prologue commands with `; ` and prepends them to
  `exec <command>`.

**Create `source/test/bates/middleware/asdf_test.exs`**

- `apply/2` appends the asdf source line to the prologue.
- Existing prologue entries are preserved and ordered before the asdf
  line.

**Create `source/test/bates/middleware/port_test.exs`**

- `apply/2` with `:assigned_port` set adds `"PORT"` to environment.
- `apply/2` without `:assigned_port` returns the invocation unchanged.

**Create `source/test/bates/middleware_test.exs`**

- `Registry.lookup/1` returns `{:ok, module}` for `"asdf"` and `"port"`.
- `Registry.lookup/1` returns `{:error, :unknown}` for an unknown name.
- `apply_pipeline/3` calls each module in order and threads the
  invocation through.

## Phase 2: Config Parsing and Validation

Wire app-level + service-level middleware into the `Service` struct and
fail fast on unknown names.

### Files

**Update `source/lib/bates/config.ex`**

- In `build_application/1`, read `options["middleware"]` (default `[]`)
  as the app-level list.
- Pass the app-level list into both `build_single_service/3` and
  `build_multi_services/3` (rename arity).
- In `build_multi_services/3`, concatenate `app_middleware ++
  service_middleware`. Then call `auto_append_port/2` to append `"port"`
  if the service has a non-nil hostname and `"port"` isn't already in
  the list.
- In `build_single_service/3`, the single service is always routable
  (hostname comes from app name), so the merged list is `app_middleware
  ++ ["port"]` (deduplicated).
- Add `validate_middleware/1`: walks every service's middleware list and
  verifies each name resolves via `Bates.Middleware.Registry.lookup/1`.
  Returns `:ok` or `{:error, {:unknown_middleware, name}}`.
- `applications/1` runs `validate_middleware/1` after building all
  applications. On error, return the error tuple instead of the list.
- Decision: keep the merged list as the string names for now. The
  Service struct stays the same shape (list of strings); resolution to
  modules happens in `App.start_service` via `Registry.lookup`. This
  keeps the Service struct free of module references and makes config
  hot-reload (future work) easier.

**Update `source/lib/bates/process_supervisor.ex`**

- `load_applications/0` calls `Bates.Config.applications/0`. Match on
  the result: on `{:error, reason}`, raise (`raise
  "Bates configuration error: #{inspect(reason)}"`). On a list of
  tuples, proceed with `Enum.each(&start_child/1)`. A broken config
  should fail loudly during boot, not leave Bates running with no
  apps loaded.
- `load_applications/0` runs in a `Task` spawned from `start_link/1`,
  so the raise terminates the task without taking down the
  supervisor; the error is visible via the task's exit reason in
  Logger output. (No additional Logger.error call is needed — the
  unhandled exception already produces a stacktrace.)

### Tests

**Update `source/test/bates/config_test.exs`**

- App-level middleware on the application table is parsed and prepended
  to each service's list.
- Service-level middleware is appended after app-level middleware.
- `"port"` is auto-appended for services with a hostname; not appended
  for portless services.
- `"port"` is not duplicated if the user already listed it.
- Single-service shorthand picks up `middleware` from the app table.
- Unknown middleware names cause `applications/1` to return
  `{:error, {:unknown_middleware, name}}`.

**Create `source/test/fixtures/middleware_config.toml`**

- App-level `middleware = ["asdf"]`.
- One routable service with `middleware = []` (gets asdf + auto port).
- One routable service with explicit `middleware = ["port"]` (asdf +
  port, no duplicate).
- One portless worker with no middleware (gets asdf only — no auto
  port).

**Update `source/test/bates/config_test.exs`**

- Reuse `middleware_config.toml` to verify the merging cases above.

## Phase 3: Service Execution Through Pipeline

Replace the hard-coded `env_with_port` / `parse_command` path with the
middleware pipeline.

### Files

**Update `source/lib/bates/app.ex`**

- In `start_service/3`:
  - After computing `assigned_port`, build the middleware module list:
    `Enum.map(config.middleware, &Bates.Middleware.Registry.lookup!/1)`
    (add a `lookup!/1` helper to Registry that raises on unknown — at
    this point Config has already validated, so a miss is a bug).
  - Build the initial invocation:
    `%ProcessInvocation{command: config.command}`.
  - Build the context map:
    `%{assigned_port: assigned_port, service: config,
       app_name: state.name, root: state.root}`.
  - Run the pipeline:
    `invocation = Bates.Middleware.apply_pipeline(initial, modules,
    context)`.
  - Compile to a shell string:
    `command_charlist = invocation |> ProcessInvocation.compile() |>
    to_charlist()`.
  - Build env opts from `invocation.environment`:
    `env_opts = Enum.map(invocation.environment, fn {k, v} ->
       {to_charlist(k), to_charlist(v)} end)`.
  - Pass `env: env_opts` to `:exec.run_link/2`.
- Remove `env_with_port/1` and `parse_command/1`.
- Keep `assign_port/1` — Bates still owns port assignment for readiness
  checks and Caddy routing. The `port` middleware merely propagates the
  number into the env map.

### Tests

**Update `source/test/bates/app_test.exs`**

- Existing tests already exercise `PORT`. They should continue passing
  because `Config` auto-injects the `port` middleware. Verify by
  updating fixtures rather than test code.
- Add an integration test in a new `describe "middleware"` block:
  - Build a Service with `middleware: ["port"]` and a command that
    writes `PORT` to a temp file (e.g. `sh -c 'echo $PORT > /tmp/...;
    sleep 999'`). Start the App, wait for `up`, read the temp file,
    assert it matches `App.services/1`'s reported port.
  - Build a Service whose middleware adds a synthetic prologue line
    that writes a marker file, plus a command that sleeps. Verify the
    marker file exists after `up`. (Use a test-only middleware module
    defined inside the test file.)

## Phase 4: Spec Updates

Update the spec to describe the implementation as built.

### Files

**Update `specs/process-management.md`**

- "Middleware" section: clarify that the `port` middleware is applied
  automatically by Bates for services that have a hostname; users do
  not need to list it. (Today the spec example shows the user writing
  `middleware = ["port"]` on the web service — adjust the example.)
- "Process Invocation" section: note that the merge of app-level and
  service-level middleware happens at config parse time; the runtime
  only sees a single ordered list per service.
- "Service Execution" section: state that environment variables are
  passed via the OS process spawner's environment (not shell `export`)
  and that the supervised command is exec'd so signals reach it
  directly.
- Add a note that unknown middleware names cause Bates to refuse to
  start, surfaced via the configuration loader.

## What Does NOT Change

- `source/lib/bates/port_number.ex` — port allocation algorithm stays.
- `source/lib/bates/caddy.ex` — Caddy routing stays.
- `source/lib/bates/service.ex` — the existing `middleware` field is
  reused as-is; struct shape is unchanged.
- `source/lib/bates/process_supervisor.ex` — only the error-handling
  path for `Config.applications/0` changes; supervision tree is
  unchanged.
- `source/lib/bates_web/**` — dashboard, loading page, controllers, and
  plugs are not affected.
- Existing TOML configs without a `middleware` key continue to work
  identically (empty list ++ auto port = same effective behaviour as
  today's hard-coded PORT).
- Other specs (`control-interface.md`, `routing.md`, `cli.md`,
  `system-overview.md`, `sandbox/implementation-notes.md`) do not need
  changes — middleware is internal to process management.

## Where to Start

> These are pointers from the codebase survey at plan creation time.
> Files may have changed by execution time. Verify before acting.

**Core flow to trace:**

1. `Bates.Config.applications/1` in `source/lib/bates/config.ex` —
   `build_application/1` builds the `{name, root, services}` tuple.
   `build_multi_services/2` reads service-level `middleware` already
   (line 48). App-level `middleware` is not currently read.
2. `Bates.ProcessSupervisor.load_applications/0` in
   `source/lib/bates/process_supervisor.ex` — calls Config and pipes
   into `Enum.each(&start_child/1)`. Will need to handle an `{:error,
   _}` return from Config.
3. `Bates.App.start_service/3` in `source/lib/bates/app.ex`
   (lines 234–277) — current process invocation site.
   `parse_command/1` (line 359) and `env_with_port/1` (line 342) are
   the two helpers to delete.

**Existing struct:**

- `Bates.Service` (`source/lib/bates/service.ex`) already has a
  `middleware` field defaulting to `[]`. No struct change needed.

**Testing patterns:**

- `assert_eventually/1` from `source/test/support/test_helpers.ex` for
  async transitions.
- `start_supervised!({Bates.App, config_tuple})` in tests.
- `source/test/support/test_server.ex` is a small Elixir TCP server
  that binds `$PORT`. Useful as the command for the PORT integration
  test.

**Test config:**

- `source/config/test.exs` sets `poll_interval: 50` and
  `readiness_timeout: 2_000` for fast feedback.

**erlexec env option shape:**

- `:exec.run_link/2` accepts `env: [{charlist, charlist}, ...]` (charlist
  pairs). The current code already builds this in `env_with_port/1`
  (line 344) — copy that shape when converting the invocation's env
  map.
- The `env` option **merges** the supplied vars into the inherited
  environment — `PATH`, `HOME`, etc. survive (verified, see
  `experiments/2026-04-28-erlexec-env-merge/FINDINGS.md`). Prologue
  commands like `source $(brew --prefix)/...` work without splatting
  `System.get_env/0`.

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-04-28 | READY FOR AUTONOMOUS EXECUTION | All POC gaps verified via experiments. ProcessSupervisor error handling decided (raise on `{:error, _}`). Spec scope confirmed: `process-management.md` only. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

All blocking questions resolved. POC gaps verified by experiment. No
pre-work required.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| `source/test/fixtures/multi_service_config.toml` | Ready | Existing fixture. Reusable for service-level middleware tests. |
| `source/test/fixtures/middleware_config.toml` | To create | Phase 2 creates it. Not pre-work. |
| `source/test/support/test_server.ex` | Ready | Binds `$PORT`. Used by Phase 3 integration test. |
| `Bates.Service` `middleware` field | Ready | Already present, defaults to `[]`. No struct change. |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| erlexec ~> 2.3 | Installed (2.3.0) | `env: [...]` option merges with inherited env (verified). |
| toml ~> 0.6 | Installed (0.6.x) | Parses `middleware = [...]` as list of strings at both app and service scope (verified). |
| `:exec.run_link/2` shell exec semantics | Verified | `sh -c '... ; exec <cmd>'` replaces shell PID; signals reach service directly (verified). |
| asdf + brew (runtime only) | Dev-machine concern | Required only for the `asdf` middleware to actually source asdf at runtime. Unit tests don't depend on it. |

### Open Questions

| # | Question | Blocking? | Notes |
|---|----------|-----------|-------|
| 1 | ProcessSupervisor behaviour on `Config.applications/0` returning `{:error, _}` | Resolved | Raise — broken config should fail loudly during boot. Plan Phase 2 updated. |
| 2 | Service struct stores middleware as string names vs module atoms | Resolved | Strings on the struct; resolved to modules in `App.start_service` via `Registry.lookup!/1`. No existing test asserts on the field's element type. |
| 3 | `lookup!/1` raises on unknown name during start_service | Resolved | Safe: Config (Phase 2) validates before any App starts. A miss at runtime would be a bug, not a config issue. |
| 4 | Spec scope — only `process-management.md`, or others too | Resolved | Only `process-management.md` references middleware/PORT semantics. Other specs (control-interface, routing, cli, system-overview, sandbox) don't need changes. |

### POC Gaps

| # | Assumption | Result | Effort |
|---|-----------|--------|--------|
| 1 | `exec` prefix replaces shell PID; signals reach service directly | Confirmed. See `experiments/2026-04-28-exec-signal-handling/FINDINGS.md`. | Quick |
| 2 | erlexec `env` option merges with inherited env (PATH/HOME preserved) | Confirmed. See `experiments/2026-04-28-erlexec-env-merge/FINDINGS.md`. | Quick |
| 3 | `Toml.decode` parses `middleware = [...]` as a list of strings at both scopes | Confirmed. See `experiments/2026-04-28-toml-middleware-parsing/FINDINGS.md`. | Quick |
| 4 | `$(brew --prefix)/opt/asdf/libexec/asdf.sh` exists on macOS Homebrew installs | Not verified — runtime-only concern. Failure mode is a clear shell error at service startup, not a Bates bug. | Skipped |

### Pre-Work

None.

### Blockers

None identified.
