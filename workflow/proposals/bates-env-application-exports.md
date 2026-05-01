# `bates env` to Expose Application Exports — Proposal

**Status:** Draft
**Date:** 2026-04-30
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/27
**Synced:** 2026-04-30 (no comments on issue)

## Summary

Add `bates env <name>` and the `GET /processes/<name>/env` control endpoint
that backs it. The endpoint returns the union of exports published by every
service in the application as a shell-eval'able envelope, primarily for use
in a project's `.envrc` so a console started in the application directory
inherits the same connection details its services see (e.g., `$PGHOST` and
`$PGPORT` from the `postgresql` addon).

This proposal departs from the issue's "422 when not up" stance: the
endpoint triggers application boot when the app is `down` and unblocks as
soon as exports are settled — which happens at service spawn time, well
before services finish binding. This makes direnv's first `cd`-in
evaluation produce real values instead of nothing, removing the need for
`direnv reload` in the common case.

---

## Problem

The existing addon mechanism (#19) and exports machinery (#18) make
`PGPORT` and `PGHOST` available to dependent services automatically inside
the Bates supervision tree. They are not available to anything outside it
— a `psql` invocation in a developer's shell, a Rails console started by
`bin/rails c`, an ad-hoc script run from the application directory.

The motivating use case is `direnv`: putting `eval "$(bates env myapp)"` in
the project's `.envrc` so any shell rooted in the app dir picks up the
same `$PGPORT` the application's services see. That's exactly the integration
that closes the loop on dynamically-assigned ports for human use.

The wart: direnv evaluates `.envrc` once when entering a directory. If
the application is `down` at that moment — which is the common case, because
Bates is lazy and most apps aren't running until something pokes them —
`bates env` has nothing to return, and the shell has no values until the user
runs `direnv reload` after the app boots. That manual reload is the friction
point.

---

## Decided

The fundamentals from issue #27 stand:

- A single command `bates env <name>` and a single endpoint `GET
  bates.test/processes/<name>/env`.
- App-level union only. No service-level form (`bates env myapp:web`) in
  v1; revisit if a real use case appears.
- Output is POSIX `export KEY='value'` lines with single-quoted values and
  embedded `'` escaped as `'\''`. Bash and zsh only.
- On error, the CLI exits non-zero with stderr-only output and emits
  nothing on stdout, so callers wrapping in `eval` get a clean failure
  mode.
- `direnv` is the headline consumer. `direnv reload` is the recovery path
  for shells that evaluated before exports changed (e.g., a `restart`
  changed `$PGPORT`).

The design refinement (this conversation, 2026-04-30):

- **Trigger boot on demand.** When the endpoint is hit and the app is
  `down`, it triggers `App.up/1` the same way the loading page does, then
  blocks. No new explicit start step required from the user.
- **Unblock at exports-settled, not at `up`.** Exports are written to
  per-service state inside the `{:ok, pid, _}` branch of `:exec.run_link`
  in `start_service/3` — i.e., at the moment of process spawn, before TCP
  readiness polling. The endpoint returns when every service in the app
  has reached that point (or has finished its export-producing path),
  not when every service is responding.
- **No middleware purity contract needed.** The user originally explored a
  pre-allocation / static-exports path that would let `bates env` return
  without booting at all. That requires a new "compute exports without
  invocation" contract on every middleware. The chosen path doesn't —
  middleware runs once, normally, and emits exports as a side effect of
  spawning the OS process. The endpoint reads what it produced.
- **#17 stays out of scope.** Stable ports across stop/start cycles
  (#17) is a complementary improvement to direnv UX but is independent
  of this proposal. With both in place: first `cd`-in triggers boot and
  returns exports (this proposal); subsequent stop/start cycles preserve
  `$PGPORT` so the shell stays valid (#17).
- **Existing `up` UX.** When the app is already `up`, the endpoint reads
  per-service `exports` directly from state and returns immediately. This
  is the path described in #27 and is unchanged.

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted or
> executed. These are pointers to help orient, not implementation
> instructions.

**Exports storage and lifecycle:** `source/lib/bates/app.ex`.

- `init/1` (around line 53) initializes per-service state with `exports:
  %{}`.
- `start_service/3` (around line 300) computes the invocation, then on
  successful spawn writes `exports: invocation.exports` to per-service
  state at line 321 — *before* readiness polling and the `:starting`
  broadcast at line 328.
- `stop_service/3` (around line 361) resets `exports: %{}` at line 382.
- The crash-handler / `:DOWN` paths (around lines 164, 220) reset
  `exports: %{}` symmetric with `assigned_port`.
- `build_invocation/3` (around line 444) seeds environment from
  dependency exports and runs the middleware pipeline.

**App control surface:** the existing `App.up/1`, `App.down/1`,
`App.status/1`, `App.services/1` calls live in `source/lib/bates/app.ex`.
A new call (or `handle_call`) is the right place to read the union of
exports synchronously, with a way to indicate "still pending."

**PubSub topology:** `source/lib/bates/app.ex` lines 419-429.

- `broadcast_service(app, service, msg)` broadcasts on
  `"service:<app>:<service>"`. Existing messages: `{:status, "starting"}`,
  `{:status, "up"}`, `{:status, "crashed", reason}`, `{:status, "down"}`.
- `broadcast_app(app, msg)` broadcasts on `"app:<app>"`. Existing: same
  status messages with `derive_status/1`.
- A new `{:exports_settled, exports}` service-level broadcast is the
  natural fit.

**Loading page (precedent for trigger-and-wait):**
`source/lib/bates_web/controllers/loading_controller.ex` and
`specs/control-interface.md` Loading Page section. The pattern is:
subscribe to PubSub → trigger `App.up/1` → block in a receive loop
waiting for the right message → respond. The new env endpoint follows
the same skeleton, just with a different waiting target and a different
response shape.

**Existing control endpoints:**
`source/lib/bates_web/controllers/process_controller.ex` and
`source/lib/bates_web/router.ex`. The endpoint registry currently has
`/status`, `/processes/:name/start`, `/processes/:name/stop`,
`/processes/:name/restart`, `/processes/:name/logs`. `GET
/processes/:name/env` slots in next to those, with a controller action
that mirrors loading-page semantics.

**CLI entrypoint (does not exist yet):** issue #6 covers `bates`
subcommands generally. There is no `lib/bates/cli/` module yet — `bates
status`, `bates up`, `bates down`, `bates restart`, and `bates env` are
all CLI commands the codebase doesn't have. This proposal scopes only
the env command's CLI; adding the surrounding subcommand framework
should be tackled as part of #6 or a related effort.

**Spec files affected:**

- `specs/cli.md` lines 75-114 already document `bates env <name>` with
  the original "must be `up`" semantics. This proposal updates that
  section.
- `specs/control-interface.md` lines 140-162 already document `GET
  /processes/<name>/env` with the same original semantics. Same update.
- `specs/process-management.md` describes the lifecycle and exports
  mechanism; no spec change needed there beyond, possibly, naming the
  exports-settled point in the lifecycle.

**Tests:**

- `source/test/bates/app_test.exs` has the integration patterns
  (`start_supervised!`, `assert_eventually`) for app lifecycle tests; new
  cases for the early-exports broadcast belong here.
- `source/test/bates_web/controllers/process_controller_test.exs` has
  the patterns for control endpoint tests.

---

## Proposed Design

### Lifecycle event

A new PubSub message on the per-service topic:

```elixir
{:exports_settled, exports}
```

Broadcast in `start_service/3` immediately after the existing
`{:status, "starting"}` broadcast (or merged into a single
`{:status, "starting", exports}` — see Open Questions). Carries the
service's exports map. Fires for every successfully-spawned service
including ports-less ones.

A service is considered "settled" once it has either:

- Broadcast `{:exports_settled, _}` (it spawned), or
- Broadcast `{:status, "crashed", _}` (it failed during build/spawn).

### Endpoint

`GET bates.test/processes/<name>/env` becomes:

| App state at request | Behavior |
|----------------------|----------|
| Unknown | `404 {"error": "unknown application: <name>"}` |
| `down` | Trigger `App.up/1`, subscribe to per-service topics, block until every service is settled, then union exports and return `200`. |
| `starting` (already booting) | Same as `down` — subscribe and join the wait. |
| `partial` or `crashed` (any service in `:crashed`) | `422 {"name": ..., "error": "service <svc> failed: <reason>"}`. |
| `up` | Read exports from per-service state and return `200` immediately (the existing #27 path). |

Successful response shape unchanged from #27:

```json
{
  "name": "myapp",
  "exports": {
    "PGHOST": "127.0.0.1",
    "PGPORT": "52345"
  }
}
```

Conflict resolution if two services export the same key:
last-writer-wins by service start order, as already specified in
`specs/control-interface.md`.

Timeout: bound the wait by the existing `@readiness_timeout` (60s).
If the wait expires without all services settling, return
`504 {"name": ..., "error": "timed out waiting for exports"}`.

### CLI

`bates env <name>` — thin wrapper around the endpoint:

- Calls `GET /processes/<name>/env`.
- On `200`: format each `KEY=value` pair as `export KEY='value'` with
  `'\''` escaping for embedded single quotes; write to stdout.
- On any non-2xx or transport error: write a concise message to stderr,
  exit non-zero, emit nothing on stdout. Same failure-mode contract as
  #27.

### Side-effecting GET

The endpoint's `GET` triggers boot when needed. This deviates from strict
REST hygiene, but it matches the loading page's pattern (also a `GET`
that triggers boot via DNS-driven flow), and it's exactly the contract
the headline consumer (direnv `eval`) needs from a single command. The
side effect is bounded and idempotent: starting an already-up or
already-starting app is a no-op.

---

## What This Unlocks

1. `eval "$(bates env myapp)"` in a project's `.envrc` Just Works on
   first `cd`-in, even when Bates has been running but the app is
   `down`. No `direnv reload` required for the common case.
2. The first concrete consumer of exports outside the supervision tree
   ships, completing the loop for the postgresql addon (#20).
3. Other tooling (custom shell scripts, IDE integrations, ad-hoc
   `psql` from the app dir) gets a single source of truth for
   addon-supplied connection details.
4. The PubSub `:exports_settled` event is also useful internally:
   future features that need to know "has this service produced its
   exports yet" (live-updating dashboard, observability) can subscribe
   without hand-rolling state inspection.

---

## Scope

In scope:

- New `{:exports_settled, exports}` PubSub broadcast emitted from
  `start_service/3` immediately after the existing `{:status, "starting"}`
  broadcast (including for ports-less services that go directly to `up`).
- New control endpoint `GET /processes/<name>/env` returning the union
  of per-service exports, with the trigger-and-wait semantics described
  above, including the 404 / 422 / 504 / 200 cases.
- New CLI command `bates env <name>` per `specs/cli.md`.
- Spec updates to `specs/cli.md` and `specs/control-interface.md`
  reflecting the trigger-boot, wait-for-settled semantics (replacing
  the original 422-when-not-up text).
- Tests:
  - `bates env` against an `up` application returns the union of
    exports and exits 0 with formatted output.
  - `bates env` against a `down` application triggers boot, returns
    exports as soon as services have spawned (without waiting for full
    readiness), exits 0.
  - `bates env` against an unknown application returns 404 / non-zero.
  - `bates env` against an application where a service crashes during
    boot returns 422 / non-zero with stderr-only output.
  - `bates env` honors the readiness timeout (504).
  - Output formatting: embedded single quotes in export values are
    escaped correctly.
  - PubSub broadcast: a stub middleware that publishes a known export
    triggers `{:exports_settled, %{...}}` on the service topic at the
    right moment.

Out of scope:

- Port stability across stop/start cycles (#17). Complementary;
  separate proposal.
- A static-export contract / dry-runnable middleware that would let
  `bates env` return without booting services at all. Not needed for
  the direnv use case; revisit if a future feature wants pre-boot
  export inspection.
- Service-level scoping (`bates env myapp:web`). #27 already deferred
  this.
- Push-based refresh of exports into already-evaluated shells. #27
  already deferred this; `direnv reload` is the recovery path.
- Shell flavors beyond bash/zsh.
- Authentication on the env endpoint. Bates's control interface is
  bound to localhost; consistent with existing endpoints.

---

## Open Questions

1. **Broadcast shape: separate or merged?**
   Two options for the new PubSub event:
   - `{:exports_settled, exports}` as a distinct message broadcast right
     after `{:status, "starting"}`.
   - Extend the existing message: `{:status, "starting", exports}` (and
     `{:status, "up", exports}` for ports-less services).

   Distinct is cleaner semantically (status changes and export-readiness
   are different concerns) and avoids reshaping a message that has
   existing subscribers. Extending is one fewer broadcast on the wire.
   Recommend distinct unless we discover a downstream consumer that
   genuinely wants them coupled.

2. **422 detail when a service crashes.**
   What level of detail is appropriate in the response body when a
   service crashes during boot? Just the service name and a short
   reason (`"timed out waiting for port"`), or the recent log lines too?
   The latter would help direnv users diagnose without a separate
   `bates logs` call. Recommend the short reason for v1 — anything
   richer can be a follow-up.

3. **Trigger-on-GET vs explicit start.**
   The proposal has `GET /env` trigger boot if the app is down. An
   alternative is to require an explicit `POST /processes/<name>/start`
   first and have `GET /env` 422 if the app is down. The CLI would
   call both:
   ```
   bates env myapp  →  POST /start → poll → GET /env
   ```
   That's cleaner REST but pushes orchestration into every CLI client.
   Recommend keeping trigger-on-GET to match the loading page's
   precedent and keep the endpoint usable from a single `eval` line.

4. **Empty-exports response.**
   For an app whose services produce no exports (e.g., a single Rails
   service with no addons), the endpoint returns `200 {"name": "myapp",
   "exports": {}}` and the CLI emits zero `export` lines. Is that the
   right behavior, or should we 422 / emit a comment? Recommend the
   empty success — it's the most direnv-friendly and matches "the union
   of exports is the empty map" literally.
