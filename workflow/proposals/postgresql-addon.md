# Postgresql Addon - Proposal

**Status:** Draft
**Date:** 2026-04-30
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/20
**Synced:** 2026-04-30 (issue body, last updated 2026-04-29; no comments)

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
  assigned* (see Open Question 1 below).
- **Test cases.** First start runs `initdb`; second start reuses
  the existing data directory; expanded service publishes `PGPORT`
  to dependents; clean stop on `down` (no orphaned daemons).

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
  hard-codes `port: nil, hostname: nil` (relevant to Open Question
  1 below).

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
defmodule Bates.Addon.Postgresql do
  @behaviour Bates.Addon
  @behaviour Bates.Middleware

  alias Bates.ProcessInvocation

  @impl Bates.Addon
  def definition do
    %{
      command: "postgres -D $PGDATA -p $PORT",
      middleware: ["postgresql"]
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
              "[ -f #{pgdata}/PG_VERSION ] || initdb -A trust -D #{pgdata}"
            ],
        environment:
          invocation.environment
          |> Map.put("PGDATA", pgdata)
          |> Map.put("PGPORT", to_string(port))
          |> Map.put("PGHOST", "localhost"),
        exports:
          invocation.exports
          |> Map.put("PGHOST", "localhost")
          |> Map.put("PGPORT", to_string(port))
          # ...PGUSER, PGDATABASE, DATABASE_URL — see Open Question 4
    }
  end
end
```

### Registry registration

`Bates.Addon.Registry.@builtins` gains one entry:

```elixir
@builtins %{
  "postgresql" => Bates.Addon.Postgresql
}
```

Because the middleware registry falls through to the addon registry,
no separate `Bates.Middleware.Registry` entry is needed.

### Default middleware list

The addon definition's `middleware: ["postgresql"]` means the only
middleware that runs by default is the addon module itself. The
user opts into asdf (and therefore version pinning via
`.tool-versions`) by adding `middleware = ["asdf"]` at the
application level, which prepends to the addon's list:

```toml
[myapp]
root = "."
middleware = ["asdf"]
addons = ["postgresql"]
```

This produces a postgres service with middleware `["asdf",
"postgresql"]`. Without the app-level declaration, the system
`postgres` is used.

### Port assignment

Postgres needs an auto-assigned port (so multiple Bates apps coexist)
but **must not** be routed through Caddy (it's not HTTP). The
current `assign_port/1` only auto-assigns when a service has a
hostname. Resolving this is **Open Question 1** below — the addon
itself can't ship until that decision is made.

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
gets `PGHOST=localhost`, `PGPORT=<auto>`, etc. via the existing
exports-seeding path.

---

## What This Unlocks

1. Per-application Postgres clusters with no global daemon and no
   port collisions across projects.
2. Zero-configuration database connection for sibling services —
   `PGHOST`, `PGPORT`, and `PGUSER`/`PGDATABASE` (TBD) are seeded
   into every service's environment automatically via #18.
3. The first end-to-end exercise of #16 + #18 + #19 together,
   which validates the trio against a real workload (instead of
   the synthetic exports tests we have today).
4. A template for future addons (`redis`, `memcached`, etc.).

---

## Scope

In:

- New module `source/lib/bates/addon/postgresql.ex`.
- One new entry in `Bates.Addon.Registry.@builtins`.
- The port-assignment fix selected from Open Question 1
  (whichever option lands).
- New tests under `source/test/bates/addon/postgresql_test.exs`
  exercising the middleware unit (prologue idempotence, env/export
  contents).
- Integration tests under `source/test/bates/app_test.exs` (or a
  new file) that boot a real Postgres via `initdb` + `postgres`
  and verify TCP readiness, log flow, and exports propagation to
  a dependent. These will be tagged so a developer without
  Postgres on `PATH` can skip them.
- Spec update: cite `postgresql` as a concrete addon in
  `specs/process-management.md`.

Out:

- A CLI command to clean up addon data directories on app
  removal (Open Question 5).
- Explicit version override on the addon definition; users get
  `asdf` or system Postgres (Open Question 2).
- Other addons (`redis`, etc.).
- Multi-instance support (more than one Postgres per app).

---

## Open Questions

1. **Port assignment for hostname-less addon services.** The
   current `Bates.App.assign_port/1` only auto-assigns a port
   when the service has a hostname. The postgres addon has no
   hostname (it's not HTTP) but needs an auto-assigned port for
   `-p $PORT`. Three options:
   - **A. Set `hostname` on addon services anyway.** Cheap but
     creates a useless Caddy route that will silently 404. Wastes
     one port per addon for no benefit.
   - **B. Extend the addon definition to carry a port hint.**
     Add `port: :auto` (or similar) to the addon definition shape;
     have `Config.expand_addons` set `Service.port` to a sentinel
     that `assign_port/1` honors. Localized change.
   - **C. Trigger auto-assignment from the middleware list.**
     If `"port"` is on a service's middleware list, allocate a
     port. Aligns with the spec's claim that "a service with a
     `port` but no `hostname` is valid" (process-management.md
     line 76). Wider blast radius — touches existing services'
     port behavior — but eliminates the inconsistency.
   - **Recommendation:** B, with the addon's middleware list
     including `"port"` so the `Bates.Middleware.Port` runs and
     populates `$PORT` for the command line. C is conceptually
     cleaner but mixes concerns and risks regressing existing
     services. A is the worst of all.

2. **Unix socket directory.** Postgres opens a Unix socket at a
   default system path (`/tmp` or `/var/run/postgresql`), which
   collides if multiple Bates apps run Postgres concurrently.
   Options:
   - **A. Scope under the data dir.** `-c
     unix_socket_directories=<root>/.bates/postgresql/sockets`.
     Friendly to tools that prefer sockets; makes
     `psql -h <root>/.bates/postgresql/sockets` work locally.
   - **B. Disable sockets entirely.** `-c
     unix_socket_directories=''`. Forces TCP-only. Simpler but
     less convenient for ad-hoc `psql` from the project dir.
   - **Issue author leans toward A** ("probably scope"). Confirm
     the lean.

3. **Default user, database, and auth.** `initdb -A trust` makes
   the cluster password-less (correct for local dev). The default
   user is the OS user. Sub-questions:
   - Should the addon also create a database named after the
     application (e.g., `myapp`)? Pros: zero-config consumers can
     just `psql $DATABASE_URL`. Cons: now the addon does work
     beyond starting the cluster, and "named after the app" is a
     new coupling to expose to the middleware (it knows app_name
     from context, so this is doable).
   - **Recommendation:** Yes. Create `<app_name>` as a database
     on first start, alongside `initdb`. The user's app needs *a*
     database, and creating the most-likely-correct one removes
     a step. They can ignore it and create their own if they
     want.

4. **Which environment variables to export.** At minimum `PGPORT`
   and `PGHOST` (without `PGHOST=localhost`, libpq tries the Unix
   socket and fails or hits the wrong cluster). Likely candidates
   beyond that: `PGUSER` (the OS user), `PGDATABASE` (whatever
   #3 decides), `DATABASE_URL`
   (`postgres://<user>@localhost:<port>/<db>` — Rails-style
   convention).
   - **Recommendation:** Export all of them. They're cheap; users
     can ignore the ones they don't need; Rails/Phoenix/etc.
     pick up `DATABASE_URL` automatically.

5. **Cleanup on app removal.** When an application is removed
   from `config.toml`, its `<root>/.bates/postgresql` directory
   stays on disk. Options:
   - **A. Document and live with it.** Consistent with not
     auto-managing user files. The user can `rm -rf .bates/`
     when they're done.
   - **B. Add a CLI command.** `bates clean <app>` or similar.
     New scope, but rescues users from gotchas around stale
     clusters with the wrong Postgres version.
   - **Recommendation:** A. CLI is a separate proposal if it
     turns out to matter.

6. **Version handling, explicit override.** The issue author
   floats whether to add an explicit `version` field to the addon
   definition (so users can pin Postgres without `.tool-versions`).
   - **Recommendation:** Defer. Document the asdf integration in
     the spec; revisit if users actually ask for a non-asdf
     pinning mechanism.
