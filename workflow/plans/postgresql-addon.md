# Plan: Postgresql Addon

## Goal

Ship the `postgresql` addon — a per-app Postgres instance that
automatically supervises a foreground `postgres` process and exports
`PGHOST`/`PGPORT` to sibling services via the existing
dependency-seeded environment.

## Proposal

`workflow/proposals/accepted/2026-04-30-postgresql-addon.md`

## Why This Matters

The addons framework (#19) shipped without a production consumer.
Apps that want a local Postgres still hand-roll a service entry,
invent their own data directory convention, and manually plumb
`PGHOST`/`PGPORT` to dependent services. This plan delivers the
first concrete addon and exercises #16 + #18 + #19 against a real
workload. It also closes a long-standing gap between the spec's
documented `port = "auto"` TOML behavior and the actual code, which
ignores `port` on hostname-less services.

## Acceptance Criteria

- [ ] An app with `addons = ["postgresql"]` boots a postgres service
      with an auto-assigned port.
- [ ] First start runs `initdb` into `<root>/.bates/postgresql/`;
      subsequent starts skip it (verified by checking for
      `PG_VERSION`).
- [ ] A stale `postmaster.pid` (process gone) is removed in the
      prologue; a live `postmaster.pid` (process running) is left
      alone.
- [ ] The postgres process listens on `127.0.0.1:<assigned_port>`
      and on a Unix socket under `<root>/.bates/postgresql/`.
- [ ] A sibling service that depends on the postgres addon sees
      `PGHOST=127.0.0.1` and `PGPORT=<assigned_port>` in its
      environment.
- [ ] `Service.port = :auto` triggers port allocation, regardless
      of whether the service has a hostname.
- [ ] `Bates.Addons.Registry` resolves `"postgresql"` to
      `Bates.Addons.Postgresql`; cross-registry middleware lookup
      still resolves it via fall-through.
- [ ] `mix test` passes (unit tests run, integration tests excluded).
- [ ] `mix test --include integration` passes when `postgres` and
      `initdb` are on `$PATH`.
- [ ] `specs/process-management.md` has a dedicated `postgresql`
      addon section and all namespace references read
      `Bates.Addons.*` (no remaining `Bates.Addon.Registry`).

---

## Phase 1 — Rename `Bates.Addon.Registry` to `Bates.Addons.Registry`

Mechanical refactor. Move the registry file, update its module name,
and update every reference. The `Bates.Addon` behaviour stays at
`source/lib/bates/addon.ex` (singular: one behaviour, many addons).

### Files

- **Move:** `source/lib/bates/addon/registry.ex` →
  `source/lib/bates/addons/registry.ex`
  - Rename module to `Bates.Addons.Registry`.
  - The `@extra_key` test attribute can stay as `:extra_addons`
    (it's an Application env key, not part of the public API).
- **Move:** `source/test/bates/addon/registry_test.exs` →
  `source/test/bates/addons/registry_test.exs`
  - Update `alias` and `defmodule` to `Bates.Addons.RegistryTest`
    and `Bates.Addons.Registry`.
- **Edit:** `source/lib/bates/middleware/registry.ex`
  - Change `Bates.Addon.Registry.lookup_module/1` →
    `Bates.Addons.Registry.lookup_module/1`.
- **Edit:** `source/lib/bates/config.ex`
  - `alias Bates.{Addon, Middleware, Service}` → keep `Addon` alias
    pointing at the behaviour module (`Bates.Addon`); switch
    registry call from `Addon.Registry.lookup` to
    `Bates.Addons.Registry.lookup`. Easiest: drop the `Addon` alias
    if no longer used and call `Bates.Addons.Registry.lookup` and
    `Bates.Addon` (the behaviour) directly.
- **Edit:** `source/test/bates/config_test.exs`
  - Update any `Bates.Addon.Registry` references.
- **Remove (after move):** empty `source/lib/bates/addon/` directory
  if nothing else lives there.
- **Remove (after move):** empty `source/test/bates/addon/`
  directory if nothing else lives there.

### Rationale

A self-contained refactor that lands cleanly. Done first so later
phases reference the new namespace from the start. No behavior
change.

### Verify

- `mix test` passes.
- `grep -r "Bates\.Addon\.Registry" source/` returns no results.

---

## Phase 2 — Tri-state `Service.port`

Extend `Service.port` to accept `:auto`. Add an `assign_port/1`
clause that allocates the next available port for `:auto` regardless
of hostname.

### Files

- **Edit:** `source/lib/bates/service.ex`
  - The struct already allows arbitrary values for `port`. Add a
    `@type t` declaration (if absent) documenting
    `port: :auto | non_neg_integer() | nil`.
- **Edit:** `source/lib/bates/app.ex`
  - Add a new clause to `assign_port/1` (around line 511):
    ```elixir
    defp assign_port(%Service{port: :auto}), do: Bates.PortNumber.next()
    ```
  - Place it before the integer clause for symmetry, or after — any
    order works since `:auto` and `is_integer` are disjoint.
- **Edit:** `source/test/bates/app_test.exs`
  - Add a test asserting `port: :auto` triggers allocation on a
    hostname-less service.

### Rationale

This is the lift that lets the postgres addon get a port. Lands as
its own commit so the change is isolated and reviewable. No existing
service uses `:auto`, so no regression risk.

### Verify

- `mix test` passes.
- New test asserts `assigned_port` is an integer for a service with
  `port: :auto, hostname: nil`.

---

## Phase 3 — `Config` sets `port: :auto` for port-bearing addons

Update `build_addon_service/3` so that when the addon definition's
middleware list contains `"port"`, the resulting `%Service{}` has
`port: :auto`. Other addons (none today) get `port: nil` as before.

### Files

- **Edit:** `source/lib/bates/config.ex`
  - In `build_addon_service/3` (around line 130), inspect
    `definition.middleware`:
    ```elixir
    defp build_addon_service(name, definition, app_middleware) do
      port = if "port" in definition.middleware, do: :auto, else: nil

      %Service{
        name: name,
        command: definition.command,
        port: port,
        hostname: nil,
        middleware: app_middleware ++ definition.middleware,
        depends_on: []
      }
    end
    ```
- **Edit:** `source/test/bates/config_test.exs`
  - Extend the `describe "addons"` block (the existing fixtures use
    `StubSidekickAddon`) with a stub addon whose definition
    includes `"port"` in its middleware list; assert the expanded
    service has `port: :auto`.
  - Assert the existing port-less stub still produces
    `port: nil`.

### Rationale

Bridges Phase 2 (the tri-state `Service.port`) with Phase 4 (the
postgres addon). Lands separately so the config change is testable
in isolation, ahead of having a real port-bearing addon.

### Verify

- `mix test` passes.
- New fixtures assert both branches (`port: :auto` and `port: nil`).

---

## Phase 4 — `Bates.Addons.Postgresql` module

New addon module implementing both `Bates.Addon` and
`Bates.Middleware`. Register it in `Bates.Addons.Registry.@builtins`.

### Files

- **Create:** `source/lib/bates/addons/postgresql.ex`
  - Module `Bates.Addons.Postgresql`.
  - `@behaviour Bates.Addon`, `@behaviour Bates.Middleware`.
  - `definition/0` returns:
    ```elixir
    %{
      command: "postgres -D $PGDATA -p $PORT -k $PGDATA",
      middleware: ["port", "postgresql"]
    }
    ```
  - `apply/2` takes `%ProcessInvocation{}` and the context
    (`%{root: root, assigned_port: port}` when `is_integer(port)`).
    It appends to the prologue:
    1. `mkdir -p <pgdata>`
    2. `[ -f <pgdata>/PG_VERSION ] || initdb -A trust -D <pgdata>`
    3. Stale-pid guard: `if [ -f <pgdata>/postmaster.pid ]; then
       kill -0 $(head -1 <pgdata>/postmaster.pid) 2>/dev/null ||
       rm <pgdata>/postmaster.pid; fi`
    Sets `PGDATA`, `PGHOST=127.0.0.1`, `PGPORT=<port>` in
    `environment`. Adds `PGHOST`/`PGPORT` to `exports`.
- **Edit:** `source/lib/bates/addons/registry.ex`
  - `@builtins %{"postgresql" => Bates.Addons.Postgresql}`.
- **Create:** `source/test/bates/addons/postgresql_test.exs`
  - `defmodule Bates.Addons.PostgresqlTest` with
    `use ExUnit.Case, async: true`.
  - Tests:
    - `definition/0` returns the expected map (command,
      middleware list).
    - `apply/2` adds the three expected prologue lines, in order.
    - `apply/2` sets `PGDATA` to `<root>/.bates/postgresql`,
      `PGHOST` to `127.0.0.1`, `PGPORT` to the assigned port.
    - `apply/2` exports `PGHOST` and `PGPORT` only (not `PGUSER`,
      not `PGDATABASE`, not `DATABASE_URL`).
    - The stale-pid guard string contains the `kill -0` check.

### Rationale

The actual feature. Depends on Phases 1–3 (namespace, port tri-state,
config wiring) so postgres can land cleanly with no scaffolding.

### Verify

- `mix test source/test/bates/addons/postgresql_test.exs` passes.
- Full `mix test` passes.
- `Bates.Addons.Registry.lookup("postgresql")` returns
  `{:ok, %{command: "postgres ...", middleware: ["port", "postgresql"]}}`.
- `Bates.Middleware.Registry.lookup("postgresql")` returns
  `{:ok, Bates.Addons.Postgresql}` via fall-through.

---

## Phase 5 — Integration test

A test tagged `@tag :integration` that boots a real postgres via
`initdb` + `postgres`, asserts readiness, and asserts a dependent
service receives `PGHOST`/`PGPORT`. Excluded from `mix test` by
default.

### Files

- **Create:** `source/test/bates/addons/postgresql_integration_test.exs`
  - `use ExUnit.Case` (synchronous; this test boots real
    processes).
  - `@moduletag :integration`.
  - `setup` builds a temporary `root` with `File.mkdir_p!`,
    `on_exit` removes it.
  - Test starts a `Bates.App` configured with a `web` service that
    `depends_on: ["postgresql"]` and the `postgresql` addon.
  - Asserts the postgres service reaches state `up` within a
    reasonable timeout.
  - Connects via TCP to `127.0.0.1:<assigned_port>` to confirm
    postgres is accepting connections.
  - Asserts the `web` service's environment contains `PGHOST` and
    `PGPORT`.
- **Edit:** `source/test/test_helper.exs`
  - Add `ExUnit.start(exclude: [:integration])` if not already
    excluding integration tests.

### Rationale

The first end-to-end exercise of the addon framework against a real
binary. Catches regressions that unit-level mocking can't (env var
flow, exec lifecycle, readiness timing). Tagged so contributors
without postgres on `$PATH` aren't blocked.

### Verify

- `mix test` (default) excludes the integration test and passes.
- `mix test --include integration` runs and passes when `postgres`
  and `initdb` are on `$PATH`.

---

## Phase 6 — Spec updates

Update `specs/process-management.md` to cite `postgresql` as a real
addon, document the new behaviors, and reflect the namespace rename.

### Files

- **Edit:** `specs/process-management.md`
  - Update line 60 (`addons` row in the application options table)
    if the language can be tightened now that there's a concrete
    addon.
  - In the **Addons** section, replace any "hypothetical
    `postgresql`" wording with concrete claims about what the
    addon does.
  - Add a dedicated subsection (under Addons) for the `postgresql`
    addon documenting:
    - Command: `postgres -D $PGDATA -p $PORT -k $PGDATA`.
    - Default middleware list: `["port", "postgresql"]`.
    - Data directory: `<app_root>/.bates/postgresql`.
    - Unix socket directory: same as `PGDATA` (via `-k`).
    - Exported env vars: `PGHOST=127.0.0.1`, `PGPORT=<assigned>`.
    - Idempotent first-boot: `initdb` runs only when
      `PG_VERSION` is absent.
    - Stale `postmaster.pid` is removed only when its recorded
      PID is gone.
    - State persistence: `.bates/postgresql/` is not auto-cleaned
      when the addon is removed; users delete it manually.
  - Update line 377 (the "implements both `Bates.Addon` and
    `Bates.Middleware`" sentence) — change `Bates.Addon.Registry`
    to `Bates.Addons.Registry` and confirm wording is still
    accurate.
  - Update line 416 (the export-publishing sentence) to cite
    `PGHOST`/`PGPORT` (not just `PGPORT`).

### Rationale

The spec is the source of truth. Updating it last (after the code
is actually built) avoids spec drift and lets the wording reflect
the precise final shape, including any small adjustments
discovered during implementation.

### Verify

- `grep -n "Bates\.Addon\.Registry" specs/` returns no results.
- The `postgresql` addon section exists and documents the items
  listed above.

---

## What Does NOT Change

- A CLI command to clean up addon data directories on app removal.
  Documented behavior is "state persists until manually removed."
- Explicit version override on the addon definition; users get
  `asdf` or system postgres.
- Default database creation; apps run their own
  `mix ecto.create` / `db:create`.
- Additional exported env vars (`PGUSER`, `PGDATABASE`,
  `DATABASE_URL`); exports stay minimal at `PGHOST` and `PGPORT`.
- Other addons (`redis`, etc.).
- Multi-instance support (more than one postgres per app).
- Eager initialization or a `bates prepare` CLI; first-boot latency
  is accepted.

---

## Where to Start

> **Non-authoritative.** These pointers are from the codebase
> survey at plan creation time (2026-04-30). Files may have changed
> by execution time. Verify before acting.

### Core flow to trace

1. `source/lib/bates/config.ex` — `applications/1` →
   `build_application/1` → `expand_addons/4` →
   `build_addon_services/3` → `build_addon_service/3` (line 130).
   This is where addon definitions become `%Service{}` records.
2. `source/lib/bates/app.ex` — `start_service/3` (around line 300)
   calls `assign_port/1` (line 511) → `update_caddy_route/2` →
   `build_invocation/3` → `:exec.run_link/2`. Worth reading top
   to bottom; the addon plugs into this flow as a regular service.
3. `source/lib/bates/app.ex:461–478` (`seed_environment/2`) — walks
   the dependency graph and merges every transitive dependency's
   `exports` into the consumer's initial environment. This is what
   makes `PGHOST`/`PGPORT` automatically appear in dependent
   services.
4. `source/lib/bates/middleware/registry.ex` — falls through to
   `Bates.Addon.Registry.lookup_module/1` (becomes
   `Bates.Addons.Registry.lookup_module/1` after Phase 1) on a
   middleware lookup miss; this is what makes an addon's own name
   on its middleware list resolve to the addon module itself.

### Existing tests to mirror

- `source/test/bates/addon/registry_test.exs` — stub-module pattern
  (`@behaviour Bates.Addon` + `@behaviour Bates.Middleware`).
  Becomes `source/test/bates/addons/registry_test.exs` after Phase 1.
- `source/test/bates/config_test.exs` `describe "addons"` block
  (around line 197) — addon expansion fixtures (`StubSidekickAddon`).
  Extend for the `port: :auto` case in Phase 3.
- `source/test/bates/app_test.exs` exports tests (around line 491).
  `EnvironmentRecorder` and `ExportProducer` stubs in
  `source/test/support/stub_middleware.ex` are reusable templates
  for asserting that exports propagate to dependents.

### Existing middleware to model

- `source/lib/bates/middleware/asdf.ex` — sources `asdf.sh` in the
  prologue. Closest analogue to what the postgres addon's
  middleware does (prologue mutation + env vars).
- `source/lib/bates/middleware/port.ex` — sets `PORT` from
  `assigned_port`; the postgres addon's middleware list runs
  `Port` first to populate `$PORT` for the `-p $PORT` command flag.

### Spec context

- `specs/process-management.md` lines 60, 279, 314, 321, 328, 339,
  341, 353, 363, 364, 377, 396, 404, 416 currently mention addons
  or `postgresql`. Phase 6 updates these.
