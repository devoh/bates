# Postgresql Addon - Proposal

**Status:** Draft
**Date:** 2026-04-30
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/20
**Synced:** 2026-04-30 (issue body, last updated 2026-04-29; no comments)
**Refined:** 2026-04-30 (all 11 open questions resolved)

## Summary

Ship the first concrete addon: `postgresql`. A user who declares
`addons = ["postgresql"]` on an application gets a per-app Postgres
instance, automatically supervised, with `PGHOST`, `PGPORT`, and
related libpq variables exported to every sibling service through the
existing dependency-seeded environment. The addon is the first real
consumer of the addons framework (#19), the cross-service environment
exports (#18), and the service dependency graph (#16).

---

## Problem

Today, an Elixir/Rails/etc. application that wants a local Postgres
has to either lean on a globally-installed daemon (port collisions
between projects, shared role and database configuration, drift
between dev and prod) or hand-roll a service entry that runs
`postgres`. The hand-rolled version still has to invent its own
data directory convention, decide how to bootstrap the cluster on
first run, and manually plumb `PGPORT` / `PGHOST` / `DATABASE_URL`
to every service that consumes the database. The whole point of
the addons framework is to remove exactly this boilerplate. Until
`postgresql` exists, the framework has no production consumer.

---

## Decided

Settled directly in the issue body:

- **Single addon module.** With the addon-framework refactor that
  shipped on `addons-framework`, an addon is one module implementing
  both `Bates.Addon` and `Bates.Middleware`. The postgres addon
  follows that pattern; it does not split a separate `Bates.Middleware.Postgresql`.
- **Foreground process, not `pg_ctl`.** The expanded service runs
  `postgres -D <data_dir> -p <port>` directly so erlexec retains
  supervision. `pg_ctl start` daemonizes and would orphan the
  process from Bates' lifecycle.
- **Idempotent prologue.** The middleware injects shell that runs
  `initdb` only when the data directory has no `PG_VERSION` file.
  Subsequent starts skip it.
- **Data directory location.** `<app_root>/.bates/postgresql`.
  Discoverable from the project, easy to gitignore.
- **Logs flow through the existing buffer.** No separate Postgres
  log file. Postgres writes to stdout/stderr; the log buffer in
  `Bates.App` already captures both.
- **TCP readiness check is sufficient.** Postgres begins accepting
  connections only after it is fully ready, so the existing
  `:gen_tcp.connect/4` poll in `Bates.App.check_ready/2` doesn't
  need any changes — *provided the service actually gets a port
  assigned* (see "Port allocation" below).
- **Test cases.** First start runs `initdb`; second start reuses
  the existing data directory; expanded service publishes `PGPORT`
  to dependents; clean stop on `down` (no orphaned daemons).

Settled during refinement (2026-04-30):

- **Port allocation.** `Service.port` becomes a tri-state
  `:auto | integer | nil`. `Bates.App.assign_port/1` gains a clause
  for `:auto` that allocates the next available port. The postgres
  addon's middleware list is `["port", "postgresql"]` so
  `Bates.Middleware.Port` populates `$PORT` for the command line.
  This aligns the code with the spec's documented `port = "auto"`
  TOML behavior.
- **Module location and namespace.** Addons live in their own
  namespace: `Bates.Addons.*`. This proposal renames
  `Bates.Addon.Registry` to `Bates.Addons.Registry` (moving
  `source/lib/bates/addon/registry.ex` to
  `source/lib/bates/addons/registry.ex`) and adds
  `Bates.Addons.Postgresql` at
  `source/lib/bates/addons/postgresql.ex`. The `Bates.Addon`
  behaviour stays at `source/lib/bates/addon.ex` (singular: there
  is one behaviour definition, many addons).
- **Test strategy.** Unit tests assert the resulting
  `ProcessInvocation` (prologue, environment, exports) and run
  always. An integration test tagged `@tag :integration` boots
  the addon under a real config, asserts readiness reaches `up`,
  connects via libpq, and asserts a dependent service sees
  `PGHOST`/`PGPORT`. Excluded from `mix test` by default; opt in
  with `mix test --include integration`.
- **Unix socket directory.** Scoped under `PGDATA`. The command
  becomes `postgres -D $PGDATA -p $PORT -k $PGDATA`. Avoids `/tmp`
  collisions when multiple Bates apps run postgres; clients that
  prefer sockets can connect via the directory path.
- **Default database.** None. The addon brings up the cluster;
  apps create their own databases (`mix ecto.create`, `db:create`,
  etc.).
- **Exported environment variables.** Minimal: `PGHOST=127.0.0.1`
  and `PGPORT=<assigned>`. Clients that want a `DATABASE_URL` can
  build one from these; the addon stays narrow.
- **Cleanup on app removal.** Document only — `.bates/<addon>/`
  state persists until manually removed. No CLI command.
- **Postgres version pinning.** Deferred. The addon uses whatever
  `postgres`/`initdb` are on `$PATH`. Users who want a specific
  version add `"asdf"` to their service's middleware list and pin
  via `.tool-versions`.
- **Stale `postmaster.pid` recovery.** Guarded prologue step
  removes `postmaster.pid` only when its recorded PID is gone:
  `kill -0 $PID 2>/dev/null || rm postmaster.pid`. Strictly safer
  than unconditional removal; improves dev UX after crashes and
  reboots.
- **Cold-start latency.** Accept the ~5–7s first-boot tax (one-time
  per `PGDATA`). Subsequent boots skip `initdb` and are ~1–2s.
  Documented; no eager initialization.
- **Spec updates.** Add a dedicated `postgresql` section to
  `specs/process-management.md` (command, default middleware,
  exported env vars, `PGDATA` location, socket directory,
  stale-pid handling). Update namespace references throughout
  (`Bates.Addon.Registry` to `Bates.Addons.Registry`).

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is
> accepted or executed.

### Addons framework (just shipped on `addons-framework` branch)

- `source/lib/bates/addon.ex` — defines the `Bates.Addon` behaviour
  (`definition/0` returning `%{command, middleware: [name]}`).
- `source/lib/bates/addon/registry.ex` — module-keyed builtins,
  `lookup/1` returns the normalized definition, `lookup_module/1`
  exposes the module for cross-registry resolution.
- `source/lib/bates/middleware/registry.ex` — falls through to
  `Bates.Addon.Registry.lookup_module/1` on lookup miss, so an
  addon's own name on its middleware list resolves to the addon
  module itself.
- `source/lib/bates/config.ex` — `expand_addons/4` builds the
  `%Bates.Service{}` from the addon definition; `build_addon_service/3`
  hard-codes `port: nil, hostname: nil` (this proposal updates it
  to set `port: :auto` when the addon's middleware list includes
  `"port"`).

### Service lifecycle

- `source/lib/bates/app.ex:300–360` (`start_service/3`) — the start
  path. Calls `assign_port/1`, `update_caddy_route/2`,
  `build_invocation/3`, then `:exec.run_link/2`.
- `source/lib/bates/app.ex:451–456` — context map passed to every
  middleware: `%{assigned_port, service, app_name, root}`.
- `source/lib/bates/app.ex:461–478` (`seed_environment/2`) —
  walks the dependency graph and merges every transitive
  dependency's `exports` into the consumer's initial environment.
  This is what makes `PGHOST` / `PGPORT` automatically appear in
  the web service's env.
- `source/lib/bates/app.ex:511–516` (`assign_port/1`) — the
  current rule: integer `port` is honored as-is, hostname-bearing
  services get the next available port, anything else gets `nil`.
- `source/lib/bates/app.ex:137–192` (`check_ready/2`) — TCP poll
  on `assigned_port`. Skipped entirely when `assigned_port == nil`
  (line 330: such services are immediately marked `up`).

### Middleware

- `source/lib/bates/middleware.ex` — the behaviour and
  `apply_pipeline/3`.
- `source/lib/bates/middleware/asdf.ex` — sources `asdf.sh` in the
  prologue. The pattern the addon middleware will mirror.
- `source/lib/bates/middleware/port.ex` — sets `PORT` from
  `assigned_port`. No-op when `assigned_port` is `nil`.
- `source/lib/bates/process_invocation.ex` — the struct the
  middleware pipeline mutates: `prologue`, `environment`, `exports`,
  `command`. `compile/1` joins the prologue with `;` and prepends
  `exec`.

### Tests to mirror

- `source/test/bates/addon/registry_test.exs` — the stub-module
  pattern (`@behaviour Bates.Addon` + `@behaviour Bates.Middleware`).
- `source/test/bates/config_test.exs:197–380` (`describe "addons"`)
  — addon expansion fixtures.
- `source/test/bates/app_test.exs:491–725` — exports tests.
  `EnvironmentRecorder` and `ExportProducer` stubs in
  `test/support/stub_middleware.ex` are reusable templates for
  asserting that exports propagate to dependents.

### Spec

- `specs/process-management.md` — Addons section (lines 299–397
  approximately) and Service Environment Exports section. The
  `postgresql` addon is mentioned as an example throughout. After
  this lands, the spec should cite it as a real addon, not a
  hypothetical.

---

## Proposed Design

### The addon module

```elixir
defmodule Bates.Addons.Postgresql do
  @behaviour Bates.Addon
  @behaviour Bates.Middleware

  alias Bates.ProcessInvocation

  @impl Bates.Addon
  def definition do
    %{
      command: "postgres -D $PGDATA -p $PORT -k $PGDATA",
      middleware: ["port", "postgresql"]
    }
  end

  @impl Bates.Middleware
  def apply(%ProcessInvocation{} = invocation, %{root: root, assigned_port: port})
      when is_integer(port) do
    pgdata = Path.join([root, ".bates", "postgresql"])

    %{
      invocation
      | prologue:
          invocation.prologue ++
            [
              "mkdir -p #{pgdata}",
              # idempotent: only initdb if cluster doesn't already exist
              "[ -f #{pgdata}/PG_VERSION ] || initdb -A trust -D #{pgdata}",
              # remove stale postmaster.pid only if its recorded PID is gone
              "if [ -f #{pgdata}/postmaster.pid ]; then " <>
                "kill -0 $(head -1 #{pgdata}/postmaster.pid) 2>/dev/null || " <>
                "rm #{pgdata}/postmaster.pid; fi"
            ],
        environment:
          invocation.environment
          |> Map.put("PGDATA", pgdata)
          |> Map.put("PGHOST", "127.0.0.1")
          |> Map.put("PGPORT", to_string(port)),
        exports:
          invocation.exports
          |> Map.put("PGHOST", "127.0.0.1")
          |> Map.put("PGPORT", to_string(port))
    }
  end
end
```

`Bates.Middleware.Port` runs first per the addon's middleware list
and sets `$PORT` (used by the command line). The addon middleware
adds `PGDATA`, `PGHOST`, and `PGPORT` to the postgres process's
environment and publishes `PGHOST`/`PGPORT` as exports for sibling
services.

### Registry registration

`Bates.Addons.Registry.@builtins` (renamed from `Bates.Addon.Registry`
as part of this work) gains one entry:

```elixir
@builtins %{
  "postgresql" => Bates.Addons.Postgresql
}
```

Because the middleware registry falls through to the addon registry,
no separate `Bates.Middleware.Registry` entry is needed.

### Default middleware list

The addon definition's `middleware: ["port", "postgresql"]` runs
`Bates.Middleware.Port` (to populate `$PORT` from the assigned
port) followed by the addon module itself. The user opts into asdf
(and therefore version pinning via `.tool-versions`) by adding
`middleware = ["asdf"]` at the application level, which prepends to
the addon's list:

```toml
[myapp]
root = "."
middleware = ["asdf"]
addons = ["postgresql"]
```

This produces a postgres service with middleware `["asdf", "port",
"postgresql"]`. Without the app-level declaration, the system
`postgres` is used.

### Port assignment

Postgres needs an auto-assigned port (so multiple Bates apps
coexist) but **must not** be routed through Caddy (it's not HTTP).
The current `assign_port/1` only auto-assigns when a service has a
hostname. This proposal extends `Service.port` to a tri-state
`:auto | integer | nil` and adds an `assign_port/1` clause that
allocates the next available port for `:auto`. The addon definition
sets `Service.port` (via `Config.expand_addons`/`build_addon_service`)
to `:auto`, and the `["port", "postgresql"]` middleware list ensures
`Bates.Middleware.Port` populates `$PORT` for the command line.

This change also closes a long-standing gap between the spec's
documented `port = "auto"` TOML behavior and the actual code, which
ignores `port` on hostname-less services.

### TOML user experience

```toml
[myapp]
root = "."
addons = ["postgresql"]

[myapp.services.web]
command = "bin/rails server -p $PORT"
hostname = true
```

That's the whole user-facing change. The web service's environment
gets `PGHOST=127.0.0.1` and `PGPORT=<assigned>` via the existing
exports-seeding path.

---

## What This Unlocks

1. Per-application Postgres clusters with no global daemon and no
   port collisions across projects.
2. Zero-configuration database connection for sibling services —
   `PGHOST` and `PGPORT` are seeded into every service's environment
   automatically via #18.
3. The first end-to-end exercise of #16 + #18 + #19 together,
   which validates the trio against a real workload (instead of
   the synthetic exports tests we have today).
4. A template for future addons (`redis`, `memcached`, etc.).

---

## Scope

In:

- Tri-state `Service.port` (`:auto | integer | nil`) in
  `source/lib/bates/service.ex`, with a new `Bates.App.assign_port/1`
  clause that allocates a port for `:auto`.
- Rename `Bates.Addon.Registry` to `Bates.Addons.Registry`: move
  `source/lib/bates/addon/registry.ex` to
  `source/lib/bates/addons/registry.ex` and update all references
  (`source/lib/bates/middleware/registry.ex`, tests, specs).
- New module `Bates.Addons.Postgresql` at
  `source/lib/bates/addons/postgresql.ex`.
- One new entry in `Bates.Addons.Registry.@builtins`.
- `Config.expand_addons` / `build_addon_service` updated to
  populate `Service.port = :auto` for addon services that need a
  port (driven off the addon definition's middleware list
  containing `"port"`).
- Unit tests at `source/test/bates/addons/postgresql_test.exs`
  asserting the middleware's effect on `ProcessInvocation`
  (prologue idempotence, stale-pid guard, env keys, export keys,
  socket directory flag). Always run.
- Integration test (new file or `source/test/bates/app_test.exs`)
  tagged `@tag :integration` that boots a real postgres via
  `initdb` + `postgres`, verifies TCP readiness, log flow, and
  exports propagation to a dependent. Excluded from `mix test` by
  default; opt in with `mix test --include integration`.
- Spec update: dedicated `postgresql` section in
  `specs/process-management.md`; namespace updates throughout
  (`Bates.Addon.Registry` → `Bates.Addons.Registry`).

Out:

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
- Eager initialization or a `bates prepare` CLI; first-boot
  latency is accepted.

---

## Open Questions

None. All resolved during refinement on 2026-04-30; see the
**Decided** section above.
