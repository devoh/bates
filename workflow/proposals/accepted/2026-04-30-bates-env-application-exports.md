# `bates env` to Expose Application Exports — Proposal

**Status:** Accepted
**Date:** 2026-04-30
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/27
**Synced:** 2026-04-30 (no comments on issue)
**Refined:** 2026-04-30

## Summary

Add `bates env <name>` and extend the existing `POST /processes/<name>/start`
control endpoint to return the union of exports published by every service
in the application. The endpoint blocks until exports settle (process spawn
time, well before TCP readiness) and returns them as JSON. The CLI is a
thin formatter that turns that JSON into shell-eval'able `export` lines,
primarily for use in a project's `.envrc` so a console started in the
application directory inherits the same connection details its services
see (e.g., `$PGHOST` and `$PGPORT` from the `postgresql` addon).

This proposal departs from the issue's "422 when not up" stance and from
its original separate `GET /env` endpoint: the existing start endpoint is
extended to carry exports in its response, triggering boot when the app is
`down` and unblocking as soon as exports are settled. This makes direnv's
first `cd`-in evaluation produce real values instead of nothing, removing
the need for `direnv reload` in the common case.

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

- A single command `bates env <name>`.
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

The design refinements (this conversation, 2026-04-30):

- **Trigger boot on demand.** When the endpoint is hit and the app is
  `down`, it triggers `App.up/1` the same way the loading page does, then
  blocks. No new explicit start step required from the user.
- **Unblock at exports-settled, not at `up`.** Exports are written to
  per-service state inside the `{:ok, pid, _}` branch of `:exec.run_link`
  in `start_service/3` — i.e., at the moment of process spawn, before TCP
  readiness polling. The endpoint returns when every service in the app
  has reached that point, not when every service is responding.
- **No middleware purity contract needed.** A pre-allocation /
  static-exports path was considered and rejected; it would require a new
  "compute exports without invocation" contract on every middleware. The
  chosen path runs middleware once, normally, and emits exports as a side
  effect of spawning the OS process.
- **#17 stays out of scope.** Stable ports across stop/start cycles
  (#17) is a complementary improvement to direnv UX but is independent.
  With both in place: first `cd`-in triggers boot and returns exports
  (this proposal); subsequent stop/start cycles preserve `$PGPORT` so the
  shell stays valid (#17).

The design refinements (refinement Q&A, 2026-04-30):

- **CLI scope.** Ship a minimum CLI scaffold (`lib/bates/cli.ex` + an
  `env` subcommand module) just sufficient to dispatch `bates env <app>`.
  Broader subcommands (`status`/`up`/`down`/`restart`) deferred to #6 or
  a related effort, but the dispatcher introduced here is the seed they
  extend.
- **PubSub broadcast shape.** A new per-app `{:exports_settled, exports}`
  message on the existing `"app:<app>"` topic, fired once the App
  GenServer has aggregated exports from every service. Consumers
  subscribe to one topic and get the merged map atomically.
- **No new env endpoint.** `GET /env/:app` is dropped from the design.
  Instead, the existing `POST /processes/<name>/start` endpoint is
  extended to block until exports settle and return them in its
  response. `bates env` becomes a thin formatter over that endpoint.
- **Response body is JSON.** Successful response: `{"status": "up",
  "exports": {...}}`. Error responses follow the same JSON shape
  (`{"status": "...", "reason": "..."}`). API endpoints in Bates always
  return JSON; plain-text or empty bodies are not used, even for errors.
- **Empty exports is a success.** When the merged exports map is empty
  (no middleware contributes any), the endpoint returns `{"status":
  "up", "exports": {}}` and the CLI prints nothing and exits 0. This is
  not an error condition.
- **Subscribe → check → trigger → wait.** The controller mirrors the
  `loading_controller.ex` pattern to avoid a subscribe/event race:
  subscribe to `"app:<app>"`, read current state from the App GenServer,
  return immediately if the app is `up` with exports populated (or 422
  if `crashed`); otherwise call `App.up/1` (idempotent) and enter a
  receive loop waiting for `{:exports_settled, exports}` with a 60s
  timeout.
- **Concurrency safety.** Concurrent calls to the endpoint while the app
  is `down` are safe by design: `App.up/1` is idempotent, and PubSub
  fan-out delivers the same `{:exports_settled, ...}` event to every
  subscribed caller. Implementation must verify `App.up/1` idempotency
  (already presumed by the loading page).
- **CLI progress feedback.** When the app isn't already `up`, the CLI
  emits a single line `bates: starting <app>...` to stderr on entry so
  the user sees something is happening (direnv prefixes stderr with
  `direnv:`). Skip when the app is already `up` and the response is
  instant.
- **Transport is HTTPS via Caddy.** The CLI talks to the existing API
  surface through Caddy with the local CA already in the user's trust
  store. No localhost-only HTTP backdoor or Unix socket added.

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
A new aggregation path is needed: when the App GenServer has observed
every service writing its exports, it computes the union and broadcasts
`{:exports_settled, exports}` once on the `"app:<app>"` topic.

**PubSub topology:** `source/lib/bates/app.ex` lines 419-429.

- `broadcast_service(app, service, msg)` broadcasts on
  `"service:<app>:<service>"`. Existing messages: `{:status, "starting"}`,
  `{:status, "up"}`, `{:status, "crashed", reason}`, `{:status, "down"}`.
- `broadcast_app(app, msg)` broadcasts on `"app:<app>"`. Existing: same
  status messages with `derive_status/1`.
- A new `{:exports_settled, exports}` app-level broadcast is added,
  fired once after every service has written its exports (or terminal-
  failed during start).

**Loading page (precedent for trigger-and-wait):**
`source/lib/bates_web/controllers/loading_controller.ex` and
`specs/control-interface.md` Loading Page section. The pattern is:
subscribe to PubSub → check current state (return immediately if
already terminal) → trigger `App.up/1` → block in a receive loop waiting
for the right message → respond. The new endpoint behavior follows the
same skeleton with `{:exports_settled, ...}` as the unblock target.

**Existing control endpoints:**
`source/lib/bates_web/controllers/process_controller.ex` and
`source/lib/bates_web/router.ex`. The endpoint registry currently has
`/status`, `/processes/:name/start`, `/processes/:name/stop`,
`/processes/:name/restart`, `/processes/:name/logs`. This proposal
extends the `start` action's response shape and waiting semantics.

**CLI entrypoint (does not exist yet):** issue #6 covers `bates`
subcommands generally. There is no `lib/bates/cli/` module yet. This
proposal introduces a minimal dispatcher (`lib/bates/cli.ex`) plus the
`env` subcommand module. The dispatcher is shaped so #6 can extend it
with `status`/`up`/`down`/`restart` later without rework.

**Spec files affected:**

- `specs/cli.md` lines 75-114 already document `bates env <name>` with
  the original "must be `up`" semantics. This proposal updates that
  section to reflect the new trigger-and-wait, JSON-over-`/start`
  contract.
- `specs/control-interface.md` lines 140-162 already document a separate
  env endpoint with the same original semantics. Update to reflect the
  removal of the separate endpoint and the extended `/start` response
  shape.
- `specs/process-management.md` is not updated. The new
  `{:exports_settled, ...}` broadcast is an internal implementation
  detail, not a user-facing contract.

**Tests:**

- `source/test/bates/app_test.exs` has the integration patterns
  (`start_supervised!`, `assert_eventually`) for app lifecycle tests; new
  cases for the exports-settled broadcast belong here.
- `source/test/bates_web/controllers/process_controller_test.exs` has
  the patterns for control endpoint tests.

---

## Proposed Design

### Lifecycle event

A new PubSub message on the per-app topic `"app:<name>"`:

```elixir
{:exports_settled, exports}
```

The App GenServer broadcasts this once after every service has either
written its exports (successful spawn — `app.ex:321`) or failed
terminally during start (e.g., `:crashed`). The payload is the merged
union of all service exports. Conflict resolution if two services
export the same key: last-writer-wins by service start order, as
already specified in `specs/control-interface.md`.

### Endpoint

`POST /processes/<name>/start` is extended:

| App state at request | Behavior |
|----------------------|----------|
| Unknown | `404 {"status": "unknown", "reason": "unknown application: <name>"}` |
| `down` | Trigger `App.up/1`, subscribe to `"app:<name>"`, block until `{:exports_settled, exports}`, then return `200 {"status": "up", "exports": {...}}`. |
| `starting` (already booting) | Same as `down` — subscribe and join the wait. |
| `up` | Read current exports from App state and return `200 {"status": "up", "exports": {...}}` immediately. |
| `crashed` (any service crashed during start) | `422 {"status": "crashed", "reason": "<service> failed: <reason>"}`. |

Successful response shape:

```json
{
  "status": "up",
  "exports": {
    "PGHOST": "127.0.0.1",
    "PGPORT": "52345"
  }
}
```

Empty exports is a success: `{"status": "up", "exports": {}}`. The CLI
prints nothing and exits 0.

Timeout: bound the wait by the existing `@readiness_timeout` (60s).
If the wait expires without all services settling, return
`504 {"status": "timeout", "reason": "timed out waiting for exports"}`.

### Controller behavior (subscribe → check → trigger → wait)

To avoid a subscribe/event race, the controller mirrors
`loading_controller.ex`:

1. Subscribe to `"app:<name>"`.
2. Read current app state and exports from the App GenServer.
3. If `up` with exports populated → return immediately (and unsubscribe).
4. If `crashed` → return 422 immediately.
5. Otherwise: call `App.up/1` (idempotent — safe even if `starting` or
   `up`).
6. Enter a receive loop waiting for `{:exports_settled, exports}` with a
   60s timeout. Return `504` on timeout.

Concurrent callers are safe by design: `App.up/1` idempotency means a
second call doesn't re-spawn anything, and PubSub fan-out delivers the
same `{:exports_settled, ...}` to every subscribed caller. Verify
idempotency in implementation; the loading page already presumes it.

### CLI

Introduce a minimal dispatcher (`lib/bates/cli.ex`) and an `env`
subcommand module. Scope here is just enough for `bates env <name>`;
broader subcommands deferred to #6.

`bates env <name>` behavior:

- Calls `POST /processes/<name>/start` over HTTPS via Caddy (system
  trust store).
- If the app isn't already `up`, write a single line
  `bates: starting <name>...` to stderr on entry. (Skip when `up` —
  response is instant.)
- On `200`: format each `KEY=value` pair in `exports` as
  `export KEY='value'` with `'\''` escaping for embedded single quotes;
  write to stdout. Empty `exports` → no stdout output, exit 0.
- On any non-2xx: write the response body's `reason` (or a concise fallback)
  to stderr, exit non-zero, emit nothing on stdout.
- On transport error: write a concise message to stderr, exit non-zero,
  emit nothing on stdout.

### Side-effecting POST

The endpoint's side effect (triggering `App.up/1` when `down`) is
explicit in the verb (`POST`), unlike the original design which used
`GET`. The `bates env` CLI is the headline caller and gets idempotent
"start me and tell me my env" semantics from a single request.

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
   future features that need to know "has this app produced its
   exports yet" (live-updating dashboard, observability) can subscribe
   without hand-rolling state inspection.
5. A minimal CLI dispatcher exists, ready to host the `status`/`up`/
   `down`/`restart` subcommands in #6 without throwaway scaffolding.

---

## Scope

In scope:

- New `{:exports_settled, exports}` PubSub broadcast on the
  `"app:<name>"` topic, fired once by the App GenServer after every
  service has written its exports (or terminal-failed during start).
- Extension of `POST /processes/<name>/start` to block until exports
  settle and return JSON `{"status": "up", "exports": {...}}` (or
  `{"status": "crashed"|"timeout"|"unknown", "reason": "..."}` on
  failure).
- Subscribe → check → trigger → wait controller pattern, mirroring
  `loading_controller.ex`.
- Verify `App.up/1` idempotency under concurrent callers.
- Minimal CLI dispatcher (`lib/bates/cli.ex`) plus `env` subcommand
  module. Output formatting, exit codes, stderr-only error reporting,
  single `bates: starting <name>...` progress line on cold-boot.
- Spec updates to `specs/cli.md` and `specs/control-interface.md`
  reflecting the new contract (replacing the original 422-when-not-up
  text and the separate-env-endpoint text).
- Tests:
  - `bates env` against an `up` application returns the union of
    exports and exits 0 with formatted output.
  - `bates env` against a `down` application triggers boot, returns
    exports as soon as services have spawned (without waiting for full
    readiness), exits 0.
  - `bates env` against an unknown application returns 404 / non-zero.
  - `bates env` against an application where a service crashes during
    boot returns 422 / non-zero with stderr-only output.
  - `bates env` honors the 60s timeout (504 / non-zero).
  - Empty-exports success path: `{"status": "up", "exports": {}}` →
    CLI prints nothing, exits 0.
  - Output formatting: embedded single quotes in export values are
    escaped correctly.
  - PubSub broadcast: a stub middleware that publishes a known export
    triggers `{:exports_settled, %{...}}` on the `"app:<name>"` topic at
    the right moment.
  - Concurrent callers receive the same exports without re-spawn.

Out of scope:

- Port stability across stop/start cycles (#17). Complementary;
  separate proposal.
- A static-export contract / dry-runnable middleware that would let
  `bates env` return without booting services at all. Not needed for
  the direnv use case.
- Service-level scoping (`bates env myapp:web`). #27 already deferred
  this.
- Push-based refresh of exports into already-evaluated shells. #27
  already deferred this; `direnv reload` is the recovery path.
- Shell flavors beyond bash/zsh.
- Authentication on the endpoint. Bates's control interface is
  bound to localhost; consistent with existing endpoints.
- A localhost-only HTTP backdoor or Unix domain socket transport for
  the CLI. HTTPS via Caddy is the only transport.
- Spec changes to `specs/process-management.md`. The new PubSub event
  is an internal implementation detail.
- Broader CLI subcommands (`status`, `up`, `down`, `restart`). Deferred
  to #6, which extends the dispatcher introduced here.

---

## Open Questions

None remaining. All four of the original open questions were resolved
during the 2026-04-30 refinement Q&A and folded into the **Decided**
section above.
