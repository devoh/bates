# Cross-Service Environment Exports — Proposal

**Status:** Accepted
**Date:** 2026-04-29
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/18
**Synced:** 2026-04-29 (no comments on issue)
**Refined:** 2026-04-29

## Summary

Add a runtime mechanism for middleware to publish environment variables
along the `depends_on` graph. A producer middleware writes to a new
`exports` field on the process invocation; a consumer's `environment`
is seeded from the union of `exports` across its transitive dependency
closure before the consumer's own middleware runs. The spec already
describes this in `specs/process-management.md` (Service Environment
Exports); this proposal turns that into runtime behavior.

---

## Problem

Service Dependency Ordering (#16, shipped in PR #23) gives services a
way to express start-order constraints, but a dependent service has no
way to learn anything about what its dependencies came up as. A
hypothetical `postgresql` middleware can assign a port for the Postgres
process, but the Rails service that depends on it can't discover that
port without the user hand-wiring it in TOML.

That hand-wiring is the exact thing addons are meant to remove. Without
a transport from producer middleware to consumer environment, addons
cannot publish their own connection details to the services that need
them, and the addons framework (#19) has nothing to ride on.

---

## Decided

The design is settled in `specs/process-management.md` (Service
Environment Exports). This proposal restates the contract for context;
no decisions are being re-litigated.

**Mechanism:**

- `Bates.ProcessInvocation` gains an `exports` field, a string-to-string
  map alongside `environment`. Default empty.
- Middleware writes to `exports` the same way it writes to `environment`.
  No new behaviour callback is needed.
- `exports` is not user-facing in TOML. Middleware-only.
- A middleware that wants a variable on its own service *and* on
  dependents writes both `environment` and `exports`. Hypothetical
  `postgresql` middleware would write `PGPORT` to both.

**Seeding:**

- When a service starts, its initial `ProcessInvocation.environment` is
  seeded with the union of `exports` from every service in its
  transitive `depends_on` closure.
- The consumer's own middleware pipeline runs on top of the seed, so
  middleware can reference, override, or extend inherited exports.
- The consumer's own middleware always wins on conflicts because it
  runs after the seed.

**Storage:**

- A producer's exports are computed during its own `build_invocation`
  call and stored on the application's per-service runtime state
  (alongside `assigned_port`).
- They are settled by the time the producer reaches `up`, which is the
  gate dependents wait on (the dependency-ordering work guarantees
  this).

**Stale window:**

- Exports are not refreshed in a running consumer when a dependency
  restarts. A consumer holding an old `PGPORT` keeps it until the
  consumer itself is restarted. Documented in the spec; matches Bates's
  stance that restarts are an explicit developer action.

**Refinements (2026-04-29):**

- *Closure mechanics.* Extract a `build_dependency_graph/1` helper that
  builds a `:digraph` with edges directed dependent → dependency from
  `state.services`. The existing `reverse_topological_order/1` uses it
  for shutdown; the new seeding step uses it for the closure. Both
  callers are responsible for `:digraph.delete/1`. Compute the closure
  via `:digraph_utils.reachable([service_name], graph)` (excluding the
  service itself), walk those vertices in `:digraph_utils.topsort/1`
  order, and fold via `Map.merge(acc, dep_exports)` so each step
  overwrites the prior. Net: deepest exports written first; direct deps
  override transitive deps; consumer middleware overrides everything by
  running on top.
- *Same-depth tie-breaking.* Accept whatever `:digraph_utils.topsort/1`
  returns. Real-world collisions among siblings are rare; the user can
  rearrange `depends_on` if it ever bites. No public ordering guarantee.
- *Storage timing.* Persist the producer's `exports` to per-service
  state only inside the `{:ok, pid, os_pid}` branch of `:exec.run_link`,
  alongside the `pid` and `started_at` writes. On the `{:error, _}`
  branch, state stays untouched — exports exist iff the OS process was
  successfully spawned.
- *Crash-handler reset.* The `:DOWN`/`:exec` exit path that handles
  crashes also resets `exports: %{}`, symmetric with `assigned_port`.
  The seeding path is unaffected (dependency ordering blocks consumers
  while a producer is `crashed`), but this keeps the simple invariant
  "exports exist iff `pid != nil`."
- *Test stubs.* Stub producer/consumer middleware modules live under
  `source/test/support/`, compiled only in `:test` via
  `elixirc_paths/1` in `mix.exs`. They register through the existing
  test-only register API (commit `ea1b4d2`). Stays consistent with the
  registry-split direction.

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted
> or executed. These are pointers to help orient, not implementation
> instructions.

**Process invocation:** `source/lib/bates/process_invocation.ex` —
struct with `prologue`, `environment`, `command`. The `compile/1`
function joins prologue commands with `;` separators and prepends `exec
` to the command. New `exports` field belongs here.

**Middleware behaviour:** `source/lib/bates/middleware.ex` — the
behaviour callback is `apply(invocation, context) :: invocation`.
`apply_pipeline/3` folds the modules. The behaviour signature does not
need to change; middleware that wants to publish exports just writes
`%{invocation | exports: ...}` like it would write `environment`.

**Built-in middleware:** `source/lib/bates/middleware/asdf.ex`,
`direnv.ex`, `port.ex`. None of them publish exports today and none
need to; they're left alone for v1.

**App GenServer:** `source/lib/bates/app.ex` is the runtime home for
the seed and storage logic.

- `init/1` (around line 53) builds the per-service state map (`config`,
  `assigned_port`, `pid`, `ready`, `started_at`, `exit_status`,
  `log_buffer`, `log_count`). A new `exports: %{}` field belongs here.
- `start_service/3` (around line 293) calls `build_invocation/3`,
  composes the OS command, and spawns via `:exec.run_link`. After
  building the invocation, the producer's exports must be persisted to
  the per-service state.
- `build_invocation/3` (around line 429) constructs the initial
  `%ProcessInvocation{command: ...}` and runs the middleware pipeline
  with a context map. The seed step belongs here: before the pipeline
  runs, replace the empty initial `environment` with the merged
  exports from the transitive `depends_on` closure.
- `stop_service/3` (around line 347) resets `pid`, `ready`,
  `started_at`, `exit_status`, `assigned_port`. It needs to also reset
  `exports` to `%{}`.
- `eligible_to_start?/2` and `start_eligible/1` (around line 271) —
  unchanged. Dependency ordering already gates consumers behind
  producers reaching `up`, which is the invariant export storage
  relies on.

**Tests:**

- `source/test/bates/process_invocation_test.exs` — covers
  `compile/1`. Add cases asserting the new `exports` field defaults
  empty and survives struct construction.
- `source/test/bates/middleware_test.exs` — covers the registry and
  the pipeline. Add a stub middleware that writes to `exports`,
  exercise it through `apply_pipeline/3`.
- `source/test/bates/app_test.exs` — needs a new dependency-graph
  fixture (or extension of the existing `multi_service_with_deps_*`
  helper) where a stub producer middleware writes a known export and
  a stub consumer middleware asserts it appears in environment.
  Existing test patterns (`start_supervised!`, PubSub subscription)
  are sufficient.

**Spec:** `specs/process-management.md` already documents the design
under "Service Environment Exports" and "Process Invocation."
Implementation work updates code to match the spec; the spec does not
need rewriting.

**Outside this proposal but relevant:**

- The addons framework (#19) attaches an implicit `depends_on` edge
  from every service to each declared addon. Once addons exist, they
  are the primary source of exports.
- A future `postgresql` middleware/addon (#20) is the first concrete
  consumer of this mechanism, publishing `PGPORT` (and possibly
  `PGHOST`, `DATABASE_URL`).

---

## Proposed Design

**Process invocation gains one field:**

```elixir
%ProcessInvocation{
  prologue: [],
  environment: %{},
  exports: %{},   # new
  command: nil
}
```

`compile/1` and the OS-process spawner are unchanged — neither
references `exports`.

**App per-service state gains one field:**

```elixir
%{
  config: %Service{},
  assigned_port: nil,
  pid: nil,
  ready: false,
  started_at: nil,
  exit_status: nil,
  log_buffer: :queue.new(),
  log_count: 0,
  exports: %{}   # new
}
```

**Build-time seeding.** `Bates.App.build_invocation/3` is extended:

1. Compute the transitive `depends_on` closure for the service being
   built. Each member is looked up in `state.services` to get its
   stored `exports` map.
2. Merge the closure's `exports` into a single map, in topological
   order with deepest dependencies first. Direct dependencies override
   transitive ones (last writer wins by traversal order, as the spec
   says).
3. Construct the initial `%ProcessInvocation{}` with `environment` set
   to that merged map (instead of `%{}`).
4. Run the existing middleware pipeline. The consumer's own middleware
   may add or override keys in `environment` — and write `exports` of
   its own — exactly as it does today.

**Build-time storage.** After `build_invocation/3` returns, but before
`:exec.run_link`, write the resulting invocation's `exports` to the
producer's per-service state (`%{service_state | exports: ...}`).
Producers must always be `up` before consumers start (enforced by
dependency ordering), so by the time any consumer's `build_invocation`
runs, every dependency in its closure has already had this step
complete.

**Stop-time clearing.** `stop_service/3` extends its existing reset to
include `exports: %{}` alongside the other field resets.

**Crash handling.** A producer that crashes never reaches `up`, so by
construction no consumer has read its exports — dependency ordering
prevents the consumer from starting. No special handling needed.

**Stale-export window.** A producer that restarts after a consumer
already started keeps writing fresh exports to its per-service state,
but the running consumer is not re-seeded. This is the spec's stated
behavior. No code is needed to enforce it; it falls out of the fact
that seeding only happens at consumer `build_invocation` time.

---

## What This Unlocks

1. The addons framework (#19) can wire connection details from
   built-in services (Postgres, Redis, etc.) to consumers without
   manual TOML.
2. The first concrete addon (#20: `postgresql`) becomes possible
   end-to-end: addon assigns a port → producer middleware exports
   `PGPORT` → consumer environment seeded → Rails boots with the
   right DATABASE_URL.
3. Custom middleware authors gain a clean way to publish environment
   variables across the dependency graph without touching App code.

---

## Scope

In scope:

- New `exports: %{}` field on `%Bates.ProcessInvocation{}` (with type
  spec update).
- New `exports: %{}` field on the App per-service runtime state.
- Extract a `build_dependency_graph/1` helper from
  `reverse_topological_order/1`; reuse it for the seeding closure.
- Seeding logic in `Bates.App.build_invocation/3`: transitive
  `depends_on` closure via `:digraph_utils.reachable/2`, walked in
  `:digraph_utils.topsort/1` order, merged into the consumer's initial
  environment (deepest first, last-writer-wins).
- Storage in `start_service/3`: producer's `exports` persisted only
  inside the `{:ok, _, _}` branch of `:exec.run_link`.
- Cleanup in `stop_service/3` *and* the crash-handler branch: reset
  `exports` to `%{}`.
- Stub producer/consumer middleware modules under
  `source/test/support/` registered via the test-only register API.
- Tests for the producer/consumer flow, transitive closure merging,
  storage gating on spawn success, and stop/crash-time clearing.

Out of scope:

- A user-facing TOML `exports` field. Middleware-only for v1 by
  design.
- Refreshing exports in a running consumer when a dependency
  restarts. Stale-export window is documented and intentional.
- Any concrete addon or middleware that uses the mechanism (e.g.,
  `postgresql`). Separate work.
- Cross-application exports. Same scope boundary as `depends_on` —
  intra-app only.
- Spec changes — already in place.
- Logging/observability of inherited exports (e.g., a dashboard view
  showing "what env this service inherited from its deps"). Diagnostic
  add-on, not core to the mechanism.
- Validation of export key shape (uppercase, valid env var name).
  Middleware authors are trusted; the spec doesn't require it.

---

## Open Questions

None remaining. All settled in refinement on 2026-04-29.
