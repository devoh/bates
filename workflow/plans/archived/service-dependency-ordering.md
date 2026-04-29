# Plan: Service Dependency Ordering

**Goal:** Add a `depends_on` field on services so an application's services
start in declared order. A service waits in `down` until each declared
sibling has reached `up`. Stops reverse the order. Validation rejects unknown
dependency names and cycles at config-load time.

**Proposal:** `workflow/proposals/accepted/2026-04-29-service-dependency-ordering.md`

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-04-29 | Plan created from accepted proposal. |
| 2026-04-29 | Audit applied: dedicated dependency fixture (`multi_service_with_deps_config.toml`) instead of mutating the existing one; added explicit acceptance criterion and test for the loading-page app-`crashed` bailout; documented `multi_service_with_deps_config/1` test helper. |

## Why This Matters

Multi-service support starts every service in an application concurrently.
This breaks Rails-style apps where the web service needs Vite assets ready
before it boots, and it blocks the addons feature (Postgres before everyone
else). The spec already describes ordered startup; this plan implements it.

Two follow-on features are blocked on this landing:
- Cross-service environment exports (#18) flow along dependency edges.
- The addons framework (#19) attaches an implicit edge from every service
  to each declared addon.

## Acceptance Criteria

- [x] `%Bates.Service{}` has a `depends_on` field defaulting to `[]`.
- [x] `Bates.Config` parses `depends_on` from each service table as a list
      of sibling service names; missing key defaults to `[]`.
- [x] `Bates.Config` returns `{:error, {:unknown_dependency, app, service,
      missing}}` when a `depends_on` entry names a service not declared in
      the same application.
- [x] `Bates.Config` returns `{:error, {:dependency_cycle, app, cycle}}`
      when the dependency graph contains a cycle. Self-loops surface as a
      length-1 cycle through the same code path.
- [x] `Bates.App.handle_call(:up, ...)` walks the dependency graph: it
      starts every service that is `down` and whose every `depends_on`
      entry currently reads as `up`. Other services remain `down` with
      `pid == nil`.
- [x] After a successful `:check_ready` transition to `up`, the App
      re-evaluates the graph and starts any newly-eligible service. Repeats
      to fixpoint as dependencies clear.
- [x] Repeated `:up` calls on a partially-up application re-evaluate the
      graph and start any `down` service whose dependencies are now met
      (including services in `crashed` state with no pid). This is the
      recovery path.
- [x] `Bates.App.handle_call(:down, ...)` stops services in reverse
      topological order: services with no remaining started dependents stop
      first. Within a level, stops are sequential. Services with `pid ==
      nil` (queued or already stopped) are skipped.
- [x] A dependency that reaches `crashed` leaves dependents in `down` with
      `pid == nil`. Application status derivation already reports `crashed`
      when any service is `crashed`; no change needed there.
- [x] The 60-second readiness timeout still measures from `started_at`,
      which is only set when a service enters `starting`. Services queued
      on dependencies do not start the timer. (Falls out of the existing
      structure; no code change.)
- [x] `BatesWeb.LoadingController` subscribes to `app:#{app_name}` in
      addition to its current per-service subscription, and returns the
      crash response when the application reaches `crashed` (covers
      upstream-dependency crashes). The app-level broadcast is
      `{:status, "crashed"}` (no details element, unlike the per-service
      `{:status, "crashed", details}`).
- [x] An integration test exercises the loading-page app-`crashed`
      bailout: a request for service B (which `depends_on` A) returns
      a crash response when A crashes, without spinning indefinitely.
- [x] A dedicated fixture
      `source/test/fixtures/multi_service_with_deps_config.toml`
      exercises a small dependency graph (e.g., web depends on vite,
      worker depends on web). The existing `multi_service_config.toml`
      stays untouched so pre-existing tests are unaffected.
- [x] `Bates.ConfigTest` covers: parsing `depends_on`, missing-name
      rejection, cycle rejection (including a self-loop case).
- [x] `Bates.AppTest` covers: ordered start (parent waits while child is
      `starting`), ordered stop, dependents stay `down` while a dependency
      is `starting`, dependents stay `down` when a dependency crashes,
      readiness timeout does not fire while a service is queued, repeated
      `:up` after a crash restarts the crashed service and unblocks
      dependents.

## Phases

### Phase 1 — Service struct and config parsing

**Files:**
- `source/lib/bates/service.ex` — add `depends_on: []` to the struct.
- `source/lib/bates/config.ex` — read the optional `depends_on` key in
  `build_multi_services/3` and populate the field. Single-service shorthand
  has no siblings, so `depends_on` is always `[]` there.

**Why grouped:** purely structural data plumbing, no validation yet.

### Phase 2 — Dependency validation

**Files:**
- `source/lib/bates/config.ex`:
  - Extend the existing validation pipeline (currently `validate_middleware`
    → `validate_services` → `validate_names`) to also validate
    dependencies. Two new checks per application:
    1. `validate_dependency_names/1` — every `depends_on` entry must name a
       service in the same application. Otherwise return
       `{:error, {:unknown_dependency, app, service, missing}}`.
    2. `validate_dependency_cycles/1` — build a directed graph from the
       services' `depends_on` edges and detect cycles via DFS or Kahn. On
       detection, return `{:error, {:dependency_cycle, app, cycle}}` where
       `cycle` is the list of service names along the cycle. Self-loops
       (length 1) are produced naturally by the same algorithm.
  - The validation pass should run per-application so error tuples can
    include the app name. Bail on first error to keep the contract simple.
- `source/test/fixtures/` — add fixtures exercising the error cases:
  - `unknown_dependency_config.toml` (a service depends on a name that
    doesn't exist).
  - `cyclic_dependencies_config.toml` (two services depending on each
    other).
  - `self_loop_dependency_config.toml` (a service listing itself).

**Why grouped:** all the config-load-time error surface lands together so
runtime code can assume a valid graph.

### Phase 3 — App lifecycle: up walk

**Files:**
- `source/lib/bates/app.ex`:
  - Replace the body of `handle_call(:up, ...)` with a graph walk: for
    every service whose `pid == nil`, check whether each `depends_on` entry
    currently reads `"up"` (use the existing `service_status_name/1`
    helper). Eligible services are started via the existing
    `start_service/3`. Others are left alone.
  - Extract the eligibility check into a private helper (e.g.,
    `eligible_to_start?/2`) that takes a service state and the full
    services map.
  - In the success branch of `handle_info({:check_ready, ...}, ...)`
    (where a service flips to `ready: true`), after persisting the
    transition, walk the remaining `down` services and start any that are
    now eligible. Continue the fixpoint by relying on subsequent
    `:check_ready` events to drive further unlocks. Extract a private
    `start_eligible/1` helper used by both `handle_call(:up, ...)` and
    this branch.

**Why grouped:** the up-walk is one cohesive behavior change; the
`:check_ready` post-hook is meaningless without the up-walk and vice
versa.

### Phase 4 — App lifecycle: down walk

**Files:**
- `source/lib/bates/app.ex`:
  - Replace `handle_call(:down, ...)` with a reverse-topological walk over
    services with `pid != nil`. Compute the topological order from the
    services' `depends_on` edges (a small helper, e.g.,
    `reverse_topological/1`, can live in `Bates.App` or a shared module).
    Walk levels back-to-front; within a level, stop services sequentially
    via the existing `stop_service/3` (which already waits for OS exit).
  - Services with `pid == nil` (queued, never started, or already stopped)
    are skipped.

**Why grouped:** mirror of Phase 3, but for shutdown. Sequencing in this
order means the up-walk tests in Phase 3 don't depend on this change.

### Phase 5 — Loading page bails on app `crashed`

**Files:**
- `source/lib/bates_web/controllers/loading_controller.ex`:
  - In `show/2`, also subscribe to `"app:#{app_name}"` alongside the
    existing service-topic subscription.
  - In `receive_until/1`, add a clause matching `{:status, "crashed"}` (the
    app-level broadcast — note it has no third element, unlike the
    service-level `{:status, "crashed", details}`) and treat it as
    `{:crashed, ""}`. Keep the existing service-level crash handling.
  - Also re-check `App.status/1` at entry: if the app is already
    `"crashed"`, bail without subscribing further.

**Why grouped:** small, isolated UI concern that depends on the lifecycle
work landing first (otherwise the new behavior is untestable end-to-end).

### Phase 6 — Test fixtures and coverage

**Files:**
- `source/test/fixtures/multi_service_with_deps_config.toml` — new
  fixture with a small dependency graph (e.g., `web` depends on `vite`,
  `worker` depends on `web`). Leave `multi_service_config.toml`
  untouched so existing config and app tests do not need updates.
- `source/test/bates/app_test.exs` — add a
  `multi_service_with_deps_config/1` helper alongside the existing
  `single_service_config/1`. Signature: takes optional command/port
  overrides, returns a `{name, root, services}` tuple with two or three
  services wired via `depends_on`. Used by the new dependency tests so
  setup boilerplate stays in one place.
- `source/test/bates/config_test.exs` — add cases for:
  - Parsing `depends_on` from TOML and populating the field.
  - Default empty list when the key is absent.
  - Unknown-name error.
  - Cycle error (two-service cycle).
  - Self-loop error.
- `source/test/bates/app_test.exs` — add cases for:
  - Two-service graph: dependent stays `down` while parent is `starting`,
    transitions to `starting` once parent reaches `up`.
  - Reverse-order `:down`: dependent stops before parent.
  - Dependent stays `down` when parent reaches `crashed`.
  - Readiness-timeout boundary: a queued service does not get hit by the
    parent's slow-start timeout (parent times out, dependent is still
    `down` with `pid == nil` and never got `started_at` set).
  - Repeated `:up` after a parent crashed: parent restarts, dependent
    eventually reaches `up`.
  - Self-up idempotency: running `:up` twice in a row on a fresh app does
    not double-start anything (eligibility check must include
    `pid == nil`, not just dependencies-up).
- Loading-page integration coverage (location: a new
  `source/test/bates_web/controllers/loading_controller_test.exs` if
  none exists, or extending the appropriate existing controller test):
  - Subscribes to `app:` topic, returns a 502 crash response when the
    app reaches `crashed` while waiting on a service whose own status
    is still `starting` or `down`.

**Why grouped:** test surface should be added together so coverage of the
new behaviors is reviewed in one pass.

### Phase 7 — Final check

**Files:**
- Run `mix format`, `mix test`, and `mix dialyzer` from `source/`.
- Walk through the spec at `specs/process-management.md` ("Service
  Dependencies") and confirm the implementation matches its claims. The
  spec is not edited by this plan; it already describes the design. If a
  discrepancy turns up, treat it as a bug in this plan, not a spec edit.

**Why grouped:** standard close-out.

## What Does NOT Change

- `specs/process-management.md` — already describes this design.
- The four-state service status model. Services blocked on dependencies
  continue to read as `down`. A distinct "queued" state is tracked as
  follow-up #22.
- The on-demand loading page's progress UI. Per-dependency progress bars
  are tracked as follow-up #21. This plan only adds the crash-bailout.
- Cross-application dependencies. `depends_on` only names siblings.
- The single-service shorthand. It has no siblings; `depends_on` is always
  empty there.
- `Bates.ProcessInvocation`, the middleware behaviour, or the middleware
  registry. Dependencies are upstream of middleware composition; the
  middleware pipeline is unaware of them.

## Where to Start

> These are pointers from the codebase survey at plan creation time. Files
> may have changed by execution time. Verify before acting.

**Core flow to trace:**
- `Bates.Config.applications/1` (`source/lib/bates/config.ex:6`) —
  pipeline: `File.read` → `Toml.decode` → `build_application/1` →
  `validate_middleware/1`. New dependency validation belongs alongside the
  existing middleware check.
- `Bates.Config.build_multi_services/3` (`source/lib/bates/config.ex:47`)
  — adds the new field to each `%Service{}`.
- `Bates.App.handle_call(:up, ...)` (`source/lib/bates/app.ex:74`) — the
  current iterate-and-start; becomes a graph walk.
- `Bates.App.handle_call(:down, ...)` (`source/lib/bates/app.ex:88`) — the
  current iterate-and-stop; becomes reverse-topo.
- `Bates.App.handle_info({:check_ready, ...}, ...)` (`source/lib/bates/app.ex:140`)
  — the `:gen_tcp.connect` success branch (lines 144–150) is where to
  trigger the post-up re-evaluation.
- `Bates.App.service_status_name/1` (`source/lib/bates/app.ex:317`) —
  reuse for the `is_dependency_up?` check.
- `BatesWeb.LoadingController.show/2` (`source/lib/bates_web/controllers/loading_controller.ex:8`)
  — extend its subscriptions and `receive_until/1`
  (`source/lib/bates_web/controllers/loading_controller.ex:56`) to handle
  the app-level crash broadcast.

**Existing test files:**
- `source/test/bates/config_test.exs` — pattern for fixture-based parse
  and error tests.
- `source/test/bates/app_test.exs` — uses `start_supervised!({App,
  config})` and asserts on PubSub messages. Dependency tests will need a
  multi-service config builder helper analogous to the existing
  `single_service_config/1`.

**Existing fixtures:**
- `source/test/fixtures/multi_service_config.toml` — has three services
  (web, vite, worker) with no dependency edges yet; the natural place to
  add `depends_on = ["vite"]` on web (and `depends_on = ["web"]` on worker
  if the test needs a chain).
- `source/test/fixtures/unknown_middleware_config.toml` — pattern for
  error-case fixtures.

**Spec:**
- `specs/process-management.md` — "Service Dependencies" section already
  documents the runtime semantics. Don't edit; verify implementation matches
  in Phase 7.

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-04-29 | READY FOR AUTONOMOUS EXECUTION | No blockers. 5 non-blocking questions resolved by re-reading the proposal. 5 POC gaps surfaced; one (broadcast shape) confirmed during the audit, the rest are verifiable during execution. Plan adjusted to use a dedicated dependency fixture, add an explicit acceptance criterion for the loading-page bailout, and document a `multi_service_with_deps_config/1` helper. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

Plan is grounded in the existing codebase, references are accurate, and the spec at `specs/process-management.md` is already aligned with the design. Pre-work is empty.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| `source/test/fixtures/multi_service_config.toml` | Ready | Exists; left untouched by this plan. |
| `source/test/fixtures/multi_service_with_deps_config.toml` | Missing (intentional) | Created in Phase 6. |
| `source/test/fixtures/unknown_dependency_config.toml` | Missing (intentional) | Created in Phase 2 for the unknown-name error case. |
| `source/test/fixtures/cyclic_dependencies_config.toml` | Missing (intentional) | Created in Phase 2 for the cycle error case. |
| `source/test/fixtures/self_loop_dependency_config.toml` | Missing (intentional) | Created in Phase 2 for the self-loop error case. |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `:digraph` Erlang stdlib | Available (deferred verification) | Stdlib in OTP. Implementation may use `:digraph` or hand-written DFS; both are acceptable per Phase 2. |
| `Phoenix.PubSub` `app:` topic | Confirmed | `Bates.App.broadcast_app/2` (`source/lib/bates/app.ex:326`) broadcasts `{:status, derive_status(state)}` where `derive_status/1` returns a string. App-level crash is `{:status, "crashed"}` with no third element. |
| `BatesWeb.LoadingController` | Confirmed | At `source/lib/bates_web/controllers/loading_controller.ex`; current shape matches plan's assumptions. |
| `Bates.App.service_status_name/1` | Confirmed | At `source/lib/bates/app.ex:317`; signature usable for the eligibility check. |
| `Bates.Config.validate_middleware/1` pattern | Confirmed | At `source/lib/bates/config.ex:82`; the new dependency validation follows the same `reduce_while`-per-app pattern. |

### Open Questions

| # | Question | Blocking? | Notes |
|---|----------|-----------|-------|
| 1 | Transitive ordering when intermediate deps already up | No | Proposal is clear: each service waits only for its direct `depends_on` to read `up`. No special-casing needed. |
| 2 | Loading-page race — app crash arriving before per-service status | No | Proposal explicitly covers this; the app-`crashed` clause in `receive_until/1` exits the receive loop early, regardless of per-service traffic. |
| 3 | Existing tests breaking due to fixture changes | No | Resolved by leaving `multi_service_config.toml` untouched and creating `multi_service_with_deps_config.toml` instead. |
| 4 | Crashed services persist with `pid == nil` until `:up` rerun | No | Intentional and proposal-confirmed; matches existing single-service behavior. |
| 5 | Fixpoint walk semantics across cascading `:check_ready` events | No | Each `:check_ready` success branch calls `start_eligible/1`; the cascade is naturally self-driving. |

### POC Gaps

| # | Assumption | Resolution / Suggested POC | Effort |
|---|-----------|---------------------------|--------|
| 1 | App-level crash broadcast is `{:status, "crashed"}` (no details). | **Confirmed during audit** — `broadcast_app/2` sends `{:status, derive_status(state)}` and `derive_status/1` returns a string. | quick |
| 2 | Cycle detection handles self-loops as length-1 cycles naturally. | Verified during Phase 2 implementation — pick `:digraph` or DFS, write a unit test for self-loop, confirm the algorithm reports `[name]` as the cycle. | quick |
| 3 | `start_supervised!` + PubSub assertion pattern is robust enough for ordered-startup tests. | Verified during Phase 6 — if ordered-startup tests are flaky, switch to receiving messages with explicit timeouts and assert on order via test-server commands rather than wall-clock timing. | medium |
| 4 | Fixpoint walk does not double-start a running service. | Verified during Phase 3 — eligibility helper must include `pid == nil`. Add the self-up idempotency test (already in acceptance criteria) to lock this in. | quick |
| 5 | `reverse_topological/1` handles diamond and multi-root graphs. | Verified during Phase 4 — write unit tests for the helper covering: linear chain, diamond (two leaves sharing a root), and multi-root disconnected components. | medium |

### Pre-Work

None. All POC gaps are either resolved during the audit or verifiable inline during the relevant phase.

### Blockers

None identified.

## Execution Notes

### Implementation choices

- **Cycle detection via `:digraph`.** OTP stdlib `:digraph` plus
  `:digraph.get_short_cycle/2` returns the cycle path for free and
  surfaces self-loops naturally as length-1 cycles. The post-processing
  helper `normalize_cycle/1` strips the trailing-vertex repetition
  produced by `get_short_cycle` so the error tuple's `cycle` list is a
  clean ordered sequence with no duplicates.
- **Topological sort.** The down walk uses
  `:digraph_utils.topsort/1` with edges directed dependent-to-dependency.
  `topsort/1` returns sources before sinks, which matches the desired
  shutdown order (dependents first).
- **Eligibility helper signature.** `eligible_to_start?/2` first
  guards on `pid == nil`, then falls through to a clause that checks
  every `depends_on` entry currently reads `"up"`. The two-clause
  shape locks in the audit's POC gap #4 (don't double-start a running
  service).
- **`start_eligible/1`.** Called from both `handle_call(:up, ...)` and
  the `:check_ready` success branch. Each `:check_ready` event drives
  the cascade by re-running the eligibility walk on the latest state.

### Deviations from the plan

- The plan called for running `mix dialyzer` in Phase 7 along with
  `mix format` and `mix test`. Dialyzer is not wired up in `mix.exs`
  and the prompt's wrap-up checklist explicitly skips it. Skipped.
- The plan instructed running `mix format` and committing fixes.
  Running `mix format` reformatted 18 files because the repo had
  pre-existing formatter drift. To keep the PR scoped, the format
  commit only includes the six files this branch otherwise touches.
  Reformatting the rest of the codebase is left as a follow-up.

### Surprises

- The first version of the loading-controller upstream-crash test
  used `sleep 999` for the crashing dependency, which races with the
  controller's own readiness deadline (both compile from the same
  `:bates :readiness_timeout` key, so they fire near-simultaneously).
  Switched the dependency command to `exit 1` so the crashed
  broadcast is immediate and deterministic.

### Spec verification

`specs/process-management.md` "Service Dependencies" already
described the implemented design (cross-app deps disallowed,
config-load-time validation, `crashed` dependency leaves dependents
`down`, readiness timeout begins on `starting`). No spec edits were
required.

### Execution Stats

| Metric | Value |
|--------|-------|
| Duration | ~14m |
| Commits | 7 |
| Files changed | 11 |
| Tests added | 13 |
| PR | #23 |
