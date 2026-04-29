# Service Dependency Ordering — Proposal

**Status:** Accepted
**Date:** 2026-04-29
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/16
**Synced:** 2026-04-29 (no comments on issue)
**Refined:** 2026-04-29 (8 lifecycle/scope questions resolved; follow-ups #21, #22 filed)

## Summary

Add a `depends_on` field at the service level so an application's
services can be started in a defined order. A service waits in `down`
until each of its declared sibling dependencies has reached `up` (TCP
readiness has succeeded). Stops reverse the order. Validation runs at
configuration load time and rejects unknown dependency names and
cycles. This proposal also introduces the runtime hook the addons
framework will rely on for its implicit dependency edges.

---

## Problem

The multi-service support proposal explicitly deferred ordering as a
future concern: all services within an application start concurrently.
This is correct for genuinely independent services, but several real
workflows need ordering:

- A Rails web service that should not begin booting until its Vite dev
  server is serving assets.
- A worker that needs a local queue or cache process up first.
- The upcoming addons feature, where every other service in an
  application implicitly waits for the addon (e.g., Postgres) to be
  ready before starting.

Without ordering, the user has no way to express these relationships
short of giving up on Bates managing the dependency at all (running it
out of band, or pre-starting the dependency by hand).

---

## Decided

The design was settled in conversation alongside the issue itself and
the cross-service environment exports work. Decisions reflected here
are already represented in `specs/process-management.md` (Service
Dependencies).

**Configuration:**

- `depends_on` is a flat list of sibling service names within the same
  application. Not a richer record form (e.g., `{ service = "vite",
  wait = "up" }`). Future expansion to a richer form remains additive
  if a use case emerges.
- Cross-application dependencies are out of scope. `depends_on` may
  only name services declared in the same application table.

**Validation (at configuration load time):**

- Reject when a `depends_on` entry names a service that does not exist
  in the same application.
- Reject when the dependency graph contains a cycle.
- Errors are surfaced by the configuration loader before any
  application is supervised, the same path used today for unknown
  middleware names.

**Runtime semantics:**

- "Up" means TCP readiness has succeeded. A dependency is treated as
  ready only when it reaches `up`, not merely `starting`.
- Bringing an application `up` walks the dependency graph: services
  with no remaining unmet dependencies start in parallel; the rest
  start as their dependencies reach `up`.
- Bringing an application `down` reverses the order: dependents stop
  before their dependencies.
- A dependency that crashes leaves dependents in `down`. The
  application status derivation already covers this case (any service
  `crashed` makes the application `crashed`).
- The 60-second readiness timeout begins when a service enters
  `starting`, not when it is queued waiting on dependencies. A slow
  dependency cannot cause its dependents to time out before they have
  a chance to run.
- The on-demand startup flow still triggers the full application; the
  loading page subscribes to whichever specific service was requested
  and redirects when that service reaches `up`, regardless of where it
  sits in the graph.
- The loading page also subscribes to application status and bails out
  with the existing crash error page when the app reaches `crashed`,
  so an upstream-dependency crash does not leave a user staring at an
  indefinite spinner. Richer per-dependency progress UI is tracked
  separately (#21).

**Lifecycle edge cases:**

- Re-running `:up` on a partially-up application re-evaluates the
  graph: any service currently `down` (including a `crashed` service
  with no pid) whose dependencies are satisfied gets started. Repeated
  `:up` is the recovery action for crashed dependencies.
- `:up` returns after kicking off the initially-eligible services
  (those with no `depends_on`); remaining services start later as
  their dependencies reach `up`. The handler is non-blocking, matching
  current behavior.
- `:down` stops anything with `pid != nil` in reverse topological
  order, regardless of whether the service is `starting` or `up`.
  Queued services (no pid) are already effectively down and are
  skipped.
- Within a single level of the reverse topological walk, stops happen
  sequentially. Intra-level parallelism is deferred; not worth the
  complexity for v1.
- Cycle detection naturally catches self-loops (a service listing
  itself in `depends_on`) as length-1 cycles. No special-case code is
  needed; error formatting just has to read sensibly when the cycle
  path is a single service.

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted
> or executed. These are pointers to help orient, not implementation
> instructions.

**Service struct:** `source/lib/bates/service.ex` defines the
`%Service{}` config struct with `name`, `command`, `port`, `hostname`,
and `middleware`. A new `depends_on` field belongs here.

**Config parsing:** `source/lib/bates/config.ex` reads `config.toml`
and constructs the application/service tree. `build_multi_services/3`
maps each service table to a `%Service{}`. Validation today is limited
to `validate_middleware/1` (unknown names). Dependency-name and cycle
checks belong in the same validation pass.

**Application GenServer:** `source/lib/bates/app.ex` is the runtime
home for the lifecycle changes:

- `init/1` builds the per-service state map but does not represent
  dependency relationships.
- `handle_call(:up, ...)` iterates `state.services` and starts each
  service whose `pid` is `nil`. This needs to become a graph walk.
- `handle_call(:down, ...)` mirrors that and likewise needs reversed
  topological order.
- `handle_info({:check_ready, service_name}, ...)` is where a service
  transitions from `starting` to `up`. This is the natural place to
  trigger dependents whose remaining unmet dependencies have just
  cleared.
- `service_status_name/1` derives the four-state value from runtime
  fields (`pid`, `ready`, `exit_status`). A service waiting on
  dependencies must continue to read as `down` — the state machine
  already supports this without a new state.

**Tests:**

- `source/test/bates/config_test.exs` covers config parsing today;
  needs cases for `depends_on` parsing, missing-name rejection, cycle
  rejection.
- `source/test/bates/app_test.exs` covers the existing lifecycle;
  needs cases for ordered start, ordered stop, dependents staying
  `down` while a dependency is `starting`, dependents staying `down`
  when a dependency crashes, and the readiness-timeout boundary
  (timeout does not start until the service itself enters `starting`).
- `source/test/fixtures/multi_service_config.toml` — an additional
  fixture (or extension of this one) is the cleanest way to exercise
  the full graph behavior.

**Spec:** `specs/process-management.md` already documents the design
under "Service Dependencies" and links to it from "Application
Lifecycle." Implementation work updates code to match the spec; the
spec does not need rewriting.

**Outside this proposal but relevant:**

- The cross-service environment exports issue (#18) seeds a consumer's
  environment from its dependency closure. That work depends on this
  proposal landing first.
- The addons framework (#19) attaches an implicit `depends_on` edge
  from every other service to each declared addon. Same dependency.

---

## Proposed Design

**Service struct gains one field:**

```elixir
%Service{
  name: ...,
  command: ...,
  port: ...,
  hostname: ...,
  middleware: ...,
  depends_on: []   # list of sibling service names
}
```

**Config parsing.** `Bates.Config.build_multi_services/3` reads
`depends_on` from each service's TOML table (default empty list) and
populates the new field. The validation pass is extended:

- For each service, verify every `depends_on` entry names another
  service in the same application; otherwise return
  `{:error, {:unknown_dependency, app, service, missing}}`.
- Build the per-application directed graph from `depends_on` edges and
  detect cycles (e.g., via Kahn's algorithm or DFS). On detection,
  return `{:error, {:dependency_cycle, app, cycle}}`.
- Validation runs alongside the existing middleware-name check, before
  any application is supervised.

**App GenServer state.** Each per-service entry gains a notion of
"unmet dependencies." Concretely, the start path looks at the current
service map and decides which services have all dependencies in `up`.
The simplest representation is to store `depends_on` on the service
state and compute readiness on demand in `handle_call(:up, ...)` and
in the post-`:check_ready` "did anyone become startable?" pass — no
additional state field is required, just a helper.

**Up flow.** `handle_call(:up, ...)` becomes:

1. Identify services that are `down` and have no `depends_on`, or
   whose every `depends_on` entry already reads as `up`. Start each
   in parallel (the existing `start_service/3`).
2. Other services remain `down`. Nothing to do for them yet.
3. After every successful transition to `up` (i.e., the success branch
   in `handle_info({:check_ready, ...}, ...)`), re-run step 1 over
   services still `down`. Any whose dependencies are now satisfied
   start.

This is a fixpoint walk driven by `:check_ready` events; no new
scheduler primitive is needed.

**Down flow.** `handle_call(:down, ...)` walks the graph in reverse
topological order: services with no dependents stop first, then their
dependencies, etc. Because stopping is synchronous (the existing
`stop_service/3` waits for the OS process to exit), this is a
straightforward reversed traversal. Services whose dependents have
already stopped become eligible.

**Crash handling.** If a dependency reaches `crashed` instead of `up`,
its `:check_ready` success branch never fires, so dependents waiting
on it stay `down`. The application status derivation already reports
`crashed` when any service is `crashed`. No new branch needed.

**Readiness timeout.** The existing 60-second timer in
`handle_info({:check_ready, ...}, ...)` measures from `started_at`,
which is set when the service enters `starting`. Services that are
queued waiting on dependencies have not entered `starting`, so the
timer has not started. No code change needed for this property — it
falls out of the existing structure.

**Spec.** No changes — the spec already describes this design.

---

## What This Unlocks

1. Rails-like applications can express the order their services need
   to come up in (Vite before Rails, queue before worker).
2. The cross-service environment exports issue (#18) can land —
   exports flow along the dependency edge, which now exists.
3. The addons framework (#19) can attach implicit dependency edges
   from every service to its declared addons, which is how addon
   exports (e.g., Postgres `PGPORT`) reach consumers.
4. Future addons (#20: `postgresql`) become possible end-to-end:
   declared addon → implicit edge → exports flow → consumers boot
   with connection details set.

---

## Scope

In scope:

- New field `depends_on` on the `%Service{}` struct (service-level
  only).
- TOML parsing of the new field in `Bates.Config`.
- Validation: unknown dependency name, cycle detection (including
  length-1 self-loops via the same algorithm).
- `App` lifecycle changes: ordered up via fixpoint walk, ordered down
  via reverse traversal (sequential within levels), crash propagation
  behavior, idempotent `:up` for recovery.
- Loading page subscribes to app status so it bails on `crashed`
  rather than spinning indefinitely when an upstream dep crashes.
- Test coverage for parsing, validation errors, ordered start, ordered
  stop, crashed-dependency behavior, and the readiness-timeout
  boundary.
- A test fixture exercising a small multi-service graph.

Out of scope:

- Cross-application dependencies. `depends_on` is a service-level
  field only; app-level dependencies would need their own design and
  are not anticipated.
- Richer dependency form (`{ service = "vite", wait = "..." }`).
- A distinct "queued" / "waiting" service state. Services blocked on
  dependencies continue to read as `down`. Tracked as a follow-up
  (#22).
- Per-dependency progress UI on the on-demand loading page. Tracked
  as a follow-up (#21).
- Spec changes — already in place.
- Per-service opt-out flags. (Used by addons via "do not declare it as
  an addon" rather than a service-level flag.)

---

## Open Questions

None blocking. The original issue's three open questions were resolved
in design conversation and reflected in the spec:

1. Cross-application dependencies → **out of scope, intra-app only.**
2. Richer `depends_on` form → **flat list of names; richer form is
   future-additive if needed.**
3. Readiness timeout interaction → **timer starts when the service
   enters `starting`; time spent waiting on dependencies does not
   count.**
