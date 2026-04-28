# Middleware System - Proposal

**Status:** Accepted
**Date:** 2026-04-28
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/5
**Synced:** 2026-04-28 (no comments)
**Refined:** 2026-04-28

## Summary

Implement a middleware pipeline that transforms service configuration into
process invocations at init time. Middleware can add prologue commands
(shell setup) and environment variables. This replaces the current
hard-coded `PORT` handling with a general-purpose, extensible system.

---

## Problem

Today, `PORT` assignment is a special case baked into `App.start_service/3`.
The `env_with_port/1` function builds the erlexec env list, and
`parse_command/1` passes the command through as-is. There's no way to:

- Source a runtime version manager (like asdf) before running the command.
- Add arbitrary environment variables per service.
- Compose setup steps — e.g., source asdf, *then* set PORT.

The spec already describes a middleware system with a process invocation
model (prologue + environment + command), but none of it is implemented.
Services that need asdf or other shell setup currently can't work through
Bates without the user baking everything into their command string.

---

## Decided

From the spec (accepted as part of multi-service support):

- **Two levels of middleware:** application-level (all services) and
  service-level (after application-level). Ordering within each level
  is the user's responsibility.
- **Two built-in middleware:** `asdf` (sources asdf.sh into the prologue)
  and `port` (sets `PORT` env var for services with a port).
- **Process invocation model:** `environment` exported first, `prologue`
  commands run in order, `command` runs last via exec.
- **Single shell context:** everything runs in one shell invocation so
  prologue side effects (PATH changes, shims) are inherited by the
  command.

From refinement:

- **Merge at config parse time:** app-level middleware is concatenated
  with service-level middleware in `Config`, so each service carries its
  full ordered pipeline. The rest of the system only sees one list per
  service.
- **`port` middleware is implicit:** auto-injected for services with a
  port. Users don't need to add it manually. Preserves zero-config
  behavior for the common case (hostname implies port implies PORT env).
- **Environment via erlexec `env` option:** middleware-set environment
  variables are passed to `:exec.run_link` via its `env` option, not
  shell `export`. Avoids escaping issues. Prologue commands still
  inherit the env vars inside the shell.
- **`exec` prefix on command:** the compiled shell string uses `exec` on
  the final command so the shell replaces itself with the service
  process. Signals reach the process directly.
- **Unknown middleware fails at config parse:** if a middleware name isn't
  in the registry, `Config.applications/0` returns an error. Bates won't
  start with a broken config.
- **Callback receives a context map:** `apply(invocation, context)` where
  `context` is a map with keys like `:assigned_port`, `:service`,
  `:app_name`, `:root`. Each middleware takes what it needs.
- **Unit + integration tests:** unit tests for each middleware transform,
  plus an integration test that verifies the compiled shell command
  executes correctly with env and prologue inherited.

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted or
> executed. These are pointers to help orient, not implementation
> instructions.

- **Service struct:** `source/lib/bates/service.ex` — already has a
  `middleware` field (list of strings, defaults to `[]`).

- **Config parsing:** `source/lib/bates/config.ex` — `build_multi_services/2`
  already reads `middleware` from TOML into the Service struct. However,
  `build_single_service/2` does not, and there is no parsing of app-level
  `middleware` from the TOML table. The config returns `{name, root, services}`
  tuples — app-level middleware would need to be threaded through here or
  resolved into each service's list at parse time.

- **Service execution:** `source/lib/bates/app.ex` — `start_service/3`
  currently builds the command via `parse_command/1` (just `to_charlist`),
  the env via `env_with_port/1` (just PORT), and passes both to
  `:exec.run_link/2`. This is where the process invocation would be
  assembled and used. The `assign_port/1` function handles port detection
  — the `port` middleware would take over this responsibility for PORT
  env, though port assignment itself (for readiness checks and Caddy
  routing) would remain in `App`.

- **Port assignment:** `source/lib/bates/port_number.ex` — `next/0`
  binds to port 0, reads the OS-assigned port, closes the socket. This
  stays as-is; middleware calls it.

- **Tests:** `source/test/bates/config_test.exs` covers TOML parsing.
  `source/test/bates/app_test.exs` covers service lifecycle. Both will
  need updates.

---

## Proposed Design

### Process Invocation

Introduce a struct representing the assembled invocation for a service:

```
ProcessInvocation
  prologue:    [String]    — shell commands to run before the command
  environment: %{String => String} — env vars to export
  command:     String      — the supervised process command
```

At init time, each service's middleware pipeline runs in order. Each
middleware receives the current invocation and the service config, and
returns an updated invocation. The pipeline starts with an empty prologue,
empty environment, and the service's command.

### Middleware Behaviour

Each middleware is a module that implements a single callback:

```
apply(invocation, context) -> invocation
```

The `context` is a map with keys like `:assigned_port`, `:service`,
`:app_name`, `:root`. Each middleware takes what it needs and ignores
the rest. A simple map (not a struct) makes it easy to extend later.

Built-in middleware:

- **asdf** — appends `source $(brew --prefix)/opt/asdf/libexec/asdf.sh`
  to the prologue.
- **port** — adds `PORT=<assigned_port>` to the environment. This
  middleware is auto-injected for services with a port — users don't
  need to add it manually.

Middleware are resolved by name from a registry (a simple map of string
name to module). Unknown names cause a config parse error.

### Pipeline Assembly

The effective middleware list for a service is the app-level list
concatenated with the service-level list, merged at config parse time.
Each service carries its full ordered pipeline; the rest of the system
never sees the two-level distinction. Services with a port get the
`port` middleware auto-appended (after all user-specified middleware).

### Shell Execution

Environment variables from the invocation are passed via erlexec's
`env` option, keeping them out of the shell string and avoiding
escaping issues. Prologue commands and the command are compiled into
a single shell string:

```bash
prologue1; prologue2; exec command
```

This string is passed to `:exec.run_link/2` with the `env` option
set from the invocation's environment map. The `exec` prefix on the
command ensures the shell process is replaced by the actual service,
so signals reach it directly. Prologue commands inherit the env vars
set via erlexec.

### Config Changes

App-level middleware is parsed from the TOML config and merged into
each service's middleware list at parse time. The `{name, root, services}`
tuple stays unchanged — app-level middleware is invisible to the rest
of the system after parsing.

The single-service shorthand supports middleware at the app table level.
Unknown middleware names cause `Config.applications/0` to return an
error, preventing Bates from starting with a broken config.

---

## What This Unlocks

1. Applications that use asdf-managed runtimes (Ruby, Node, Python, etc.)
   can run through Bates without manual PATH hacking.
2. The hard-coded PORT special case is replaced by a composable middleware.
3. Users can combine middleware — e.g., asdf + port on a web service, asdf
   only on a worker.
4. The system is extensible for future middleware (e.g., `mise`, `nix`,
   `dotenv`, `homebrew`) without touching core service execution code.

---

## Scope

- New `ProcessInvocation` struct
- New `Middleware` behaviour and built-in implementations (`asdf`, `port`)
- Update `Config` to parse app-level middleware and merge into services
- Update `Config` to handle middleware in single-service shorthand
- Update `App.start_service/3` to build invocation via pipeline and
  execute the compiled shell command
- Remove `env_with_port/1` and `parse_command/1` (replaced by invocation)
- Update existing tests, add middleware-specific tests
- No changes to Caddy, routing, dashboard, or loading page

---

## Open Questions

None. All questions resolved during refinement.
