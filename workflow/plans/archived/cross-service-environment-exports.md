# Plan: Cross-Service Environment Exports

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-04-29 | Plan created from accepted proposal. |
| 2026-04-29 | Audit correction: `:digraph_utils.topsort/1` with edges `dependent → dependency` returns dependents first (this is *why* the existing helper is named `reverse_topological_order`). Phase 3 and the corresponding acceptance criterion now specify reversing the filtered topsort before folding so the merge walks deepest-first. |

## Goal

Add a runtime mechanism for middleware to publish environment variables along
the `depends_on` graph, seeding a consumer's initial environment with the
union of `exports` from its transitive dependency closure.

## Proposal

`workflow/proposals/accepted/2026-04-29-cross-service-environment-exports.md`

## Why This Matters

`depends_on` (PR #23) gives services start-order constraints, but a dependent
service has no way to learn anything about what its dependencies came up as.
A future `postgresql` middleware can assign a port for Postgres, but the Rails
service that depends on it can't discover that port without hand-wiring it in
TOML — exactly what addons are meant to remove. This plan provides the
transport from producer middleware to consumer environment so addons (#19) and
the first concrete addon (#20) have something to ride on.

The design is already settled in `specs/process-management.md` ("Service
Environment Exports"). This plan turns the spec into code.

## Acceptance Criteria

- [x] `%Bates.ProcessInvocation{}` has an `exports: %{}` field with type
      `%{String.t() => String.t()}`. `compile/1` is unchanged.
- [x] App per-service state map (initialized in `Bates.App.init/1`) has an
      `exports: %{}` field alongside `assigned_port`.
- [x] A `build_dependency_graph/1` private helper exists in `Bates.App`,
      building a `:digraph` from `state.services` with edges directed
      dependent → dependency. `reverse_topological_order/1` calls it.
- [x] `Bates.App.build_invocation/3` seeds the initial
      `ProcessInvocation.environment` with the union of each transitive
      dependency's stored `exports`. Closure computed via
      `:digraph_utils.reachable/2` (excluding the service itself), filtered
      from `:digraph_utils.topsort/1` of the full graph (preserving order),
      then **reversed** so dependencies (deepest) come first. Folded with
      `Map.merge(acc, dep_exports)`. Net effect: deepest exports written
      first, direct deps overwrite transitive deps, consumer middleware
      overwrites everything by running on top.
- [x] In `start_service/3`, the producer's `exports` are persisted to
      per-service state **only inside the `{:ok, pid, os_pid}` branch** of
      `:exec.run_link`. The `{:error, _}` branch leaves state untouched.
- [x] `stop_service/3` resets `exports: %{}` alongside the existing field
      resets.
- [x] The `:check_ready` timeout branch in `handle_info/2` resets
      `exports: %{}` alongside its existing field resets.
- [x] The `:EXIT` handler in `handle_info/2` resets `exports: %{}` whenever
      `pid` becomes `nil` (both clean-exit "down" and crash paths).
- [x] Stub producer and consumer middleware modules exist under
      `source/test/support/`, declaring `@behaviour Bates.Middleware`.
      Tests register them via `Bates.Middleware.Registry.register/2` and
      unregister them via `on_exit`.
- [x] `source/test/bates/process_invocation_test.exs` covers: `exports`
      defaults to `%{}`, custom values survive struct construction,
      `compile/1` ignores `exports`.
- [x] `source/test/bates/middleware_test.exs` covers a middleware that
      writes to `exports` going through `apply_pipeline/3` with the field
      preserved.
- [x] `source/test/bates/app_test.exs` covers: a producer/consumer pair
      where the producer's middleware writes a known export and the
      consumer's middleware sees it merged into `environment`; transitive
      closure (A → B → C, A's exports reach C); same-key conflict between
      direct and transitive deps resolves to the direct dep's value;
      consumer middleware writing the same key overrides the seed;
      `exports` are empty after `down`; `exports` are empty after a crash
      (timeout or non-zero exit).
- [x] All existing tests still pass.
- [x] `mix format` is clean for files this branch touched.
- [x] `specs/process-management.md` "Service Environment Exports" section
      still matches the implementation (no changes anticipated, but
      verified).

## Phases

### Phase 1: Add `exports` field to data structures

Pure plumbing. No behavior change yet.

**Files:**

- `source/lib/bates/process_invocation.ex` — add `exports: %{}` to
  `defstruct`, update the `@type t` `:: %__MODULE__{...}` to include
  `exports: %{String.t() => String.t()}`. Leave `compile/1` and
  `@enforce_keys` unchanged.
- `source/lib/bates/app.ex` — `init/1` builds the per-service state map
  via `Map.new/2`. Add `exports: %{}` to that map alongside
  `assigned_port`.
- `source/test/bates/process_invocation_test.exs` — add a small
  `describe "struct defaults"` block (or extend the existing module) with
  tests that:
  - `%ProcessInvocation{command: "x"}` has `exports == %{}`.
  - Custom exports survive: `%ProcessInvocation{command: "x", exports:
    %{"K" => "V"}}` keeps the map.
  - `compile/1` returns the same string regardless of `exports`.

**Why grouped:** these are all type/struct-level changes with no runtime
behavior. Fast to verify in isolation before any logic changes.

### Phase 2: Extract `build_dependency_graph/1` helper

Refactor with no behavior change.

**Files:**

- `source/lib/bates/app.ex` — extract a private
  `defp build_dependency_graph(services)` from
  `reverse_topological_order/1`. The helper takes the
  `state.services` map (or just the iterable of `{name, %{config:
  %Service{depends_on: ...}}}`), creates a `:digraph`, adds vertices
  for every service name, adds edges directed dependent → dependency,
  and returns the graph. **The caller is responsible for
  `:digraph.delete/1`.** `reverse_topological_order/1` becomes:

  ```elixir
  defp reverse_topological_order(state) do
    graph = build_dependency_graph(state.services)
    try do
      :digraph_utils.topsort(graph)
    after
      :digraph.delete(graph)
    end
  end
  ```

**Why grouped:** isolated refactor. Existing tests verify behavior is
preserved (the dependency-ordering tests added in PR #23 cover both up and
down ordering). Run `mix test` to confirm.

### Phase 3: Seeding logic in `build_invocation/3`

The core behavior change.

**Files:**

- `source/lib/bates/app.ex` — modify `build_invocation/3`:

  Before constructing the initial `%ProcessInvocation{}`, compute the
  seeded environment:

  1. Build the dependency graph: `graph =
     build_dependency_graph(state.services)`.
  2. Compute the closure:
     `closure_set = MapSet.new(:digraph_utils.reachable([config.name], graph)
     -- [config.name])` (drop the service itself; we only want its
     dependencies).
  3. Get a topologically ordered list, then reverse it so dependencies
     (deepest) come first. With edges directed `dependent → dependency`,
     `:digraph_utils.topsort/1` returns **dependents first** (this is why
     the existing helper that uses it is named
     `reverse_topological_order/1` — reversed relative to start-up
     order). For seeding we want **deepest first**, so we reverse:
     ```elixir
     ordered =
       graph
       |> :digraph_utils.topsort()
       |> Enum.filter(&MapSet.member?(closure_set, &1))
       |> Enum.reverse()
     ```
  4. Fold the seeded environment. With `ordered` running deepest →
     shallowest, `Map.merge(acc, dep_exports)` makes each subsequent
     (shallower) dependency overwrite the prior (deeper) one. Direct
     deps end up overwriting transitive deps:
     ```elixir
     seed =
       Enum.reduce(ordered, %{}, fn dep_name, acc ->
         dep_state = Map.fetch!(state.services, dep_name)
         Map.merge(acc, dep_state.exports)
       end)
     ```
  5. Delete the graph: `:digraph.delete(graph)`.
  6. Construct the initial invocation with `environment: seed` (instead
     of leaving it empty for the pipeline to populate from scratch).
  7. Run the existing middleware pipeline. The consumer's middleware
     can override or extend keys exactly as it does today.

  Make sure the graph is deleted on all paths (use `try/after`).

  **Sanity check the direction with an example:**
  Setup: A `depends_on = ["B"]`, B `depends_on = ["C"]`. Edges A→B, B→C.
  - `topsort(graph)` returns `[A, B, C]` (dependents first).
  - For consumer A, closure-set is `{B, C}`.
  - Filter preserves order: `[B, C]`.
  - Reverse: `[C, B]`.
  - Fold: merge C's exports first, then B's exports overwrite where they
    collide. B is the direct dep, C is transitive — direct wins. ✓

**Why grouped:** single, focused behavior change. After this phase, the
seed is computed but never persisted (because no storage step yet runs),
so transitive closure tests can be wired up but full producer→consumer
flow won't pass yet — that requires Phase 4.

### Phase 4: Persist exports on spawn success

**Files:**

- `source/lib/bates/app.ex` — in `start_service/3`'s `{:ok, pid, os_pid}`
  branch, persist `exports: invocation.exports` to the per-service state
  map alongside the existing `pid` / `started_at` writes. The post-spawn
  paths (port and no-port) both layer onto a single base `new_svc`, so a
  single write to that base propagates to both branches.

  Concretely, change:
  ```elixir
  new_svc = %{service_state | pid: pid, ready: false, exit_status: nil}
  ```
  to also include `exports: invocation.exports`.

  The `{:error, _}` branch is unchanged — state stays untouched, so
  `exports` remains whatever it was (which is `%{}` from `init/1` or
  the prior reset).

**Why grouped:** one focused change. After this, producer/consumer
end-to-end works; tests that assert exports are read by consumers will
pass.

### Phase 5: Reset exports on stop and crash

Symmetric cleanup so the rule "exports exist iff `pid != nil`" holds.

**Files:**

- `source/lib/bates/app.ex`:
  - `stop_service/3` — add `exports: %{}` to the existing reset block
    alongside `pid`, `ready`, `started_at`, `exit_status`,
    `assigned_port`.
  - `handle_info({:check_ready, _}, _)` timeout branch — add `exports:
    %{}` to the existing reset alongside `pid: nil`, `ready: false`,
    `started_at: nil`, `exit_status: :timeout`.
  - `handle_info({:EXIT, _, _}, _)` — the existing logic constructs
    `new_svc = %{svc | pid: nil}` and then layers `exit_status` onto it.
    Reset `exports: %{}` whenever `pid` becomes `nil` here (i.e., in
    every branch where the service has just exited). Simplest: include
    `exports: %{}` in the initial `new_svc` reset, before the
    `exit_status` branching.

**Why grouped:** all three reset paths need the same treatment. Doing
them together makes the invariant easy to verify and reason about.

### Phase 6: Stub middleware + tests

**Files:**

- `source/test/support/stub_middleware.ex` (new) — define small modules
  for tests:
  - `Bates.TestSupport.ExportProducer` — writes a known key/value to
    `invocation.exports`. Reads the key/value from the `context` map (so
    one module can be parameterized via context, or use multiple
    modules — author's call).
  - `Bates.TestSupport.ExportConsumer` — asserts (via the test PID, e.g.
    `send/2` to a configured pid in context) that an expected key is
    present in `invocation.environment`. Or simpler: a middleware that
    just records `invocation.environment` into a context-supplied
    process so the test can pull it out.
  - Could be one module with both producer and consumer behavior,
    parameterized by context. Author's choice — keep simple and
    descriptive.

  Each stub declares `@behaviour Bates.Middleware` and implements
  `apply/2`.

- `source/test/bates/middleware_test.exs` — add tests that:
  - A middleware writing to `exports` results in the field being set on
    the returned invocation.
  - `apply_pipeline/3` preserves `exports` across multiple middleware.

- `source/test/bates/process_invocation_test.exs` — already covered in
  Phase 1.

- `source/test/bates/app_test.exs` — extend the existing test file with
  new tests that:
  - Build an app with a producer service (using a stub middleware that
    writes `exports`) and a consumer service that `depends_on` the
    producer (using a stub middleware that captures the seeded
    `environment`).
  - Register the stub middleware via `Bates.Middleware.Registry.register/2`
    in `setup` blocks; unregister in `on_exit`.
  - Assert: producer's exports appear in consumer's environment.
  - Transitive: A → B → C; A's exports reach C through B.
  - Conflict: direct dep overrides transitive dep.
  - Consumer middleware overrides seed.
  - After `down`, producer's `exports` are `%{}`.
  - After a crash (e.g., `command = "exit 1"` for the producer, like the
    pattern used in PR #23's loading-controller test), producer's
    `exports` are `%{}`.

  Re-use existing fixture helpers (`multi_service_with_deps_*` or
  similar from PR #23) where appropriate; extend with stub-middleware
  registration as needed.

**Why grouped:** tests round out the implementation and require all
prior phases to pass.

### Phase 7: Spec verification, format, final test

**Files:**

- `specs/process-management.md` — verify the "Service Environment
  Exports" section (lines ~257-289) and "Process Invocation" table still
  align with the code. No edits anticipated, but if any wording drifts
  during implementation (e.g., the exact merge order phrasing), update
  it. The spec is the source of truth; implementation matches it.
- Run `mix format` on every file this branch touched.
- Run the full `mix test` and confirm green.

**Why grouped:** standard wrap-up.

## What Does NOT Change

- No user-facing TOML `exports` field. Middleware-only.
- No refresh of exports in a running consumer when a dependency
  restarts. The stale-export window is intentional.
- No concrete addon or middleware that uses the mechanism (e.g.,
  `postgresql`). Separate work (#19, #20).
- No cross-application exports. Same scope as `depends_on`.
- No spec rewrite — the spec already documents the design.
- No logging/observability for inherited exports. Diagnostic only.
- No validation of export key shape (uppercase, valid env var name).
  Middleware authors are trusted.
- `Bates.ProcessInvocation.compile/1` is unchanged. Exports never
  become shell text.
- `assigned_port` is not reset in the `:check_ready` timeout or `:EXIT`
  branches today. This plan does not change that — only `exports` is
  reset on crash. (The pre-existing inconsistency is out of scope.)

## Where to Start

> These are pointers from the codebase survey at plan creation time.
> Files may have changed by execution time. Verify before acting.

**Core flow to trace:**

The core path runs through `Bates.App`. `init/1` (line 53) builds the
per-service state map. `start_service/3` (line 293) calls
`build_invocation/3` (line 429) and then `:exec.run_link`. The
middleware pipeline runs inside `build_invocation/3`. Reset paths are
`stop_service/3` (line 347), `handle_info({:check_ready, _}, _)` timeout
branch (line 152), and `handle_info({:EXIT, _, _}, _)` (line 210).

**Key files and what's in them:**

- `source/lib/bates/process_invocation.ex` — small struct + `compile/1`.
  Currently has `prologue`, `environment`, `command`. Add `exports`.
- `source/lib/bates/middleware.ex` — `Bates.Middleware` behaviour
  (`apply(invocation, context) :: invocation`) and `apply_pipeline/3`.
  No signature changes needed; middleware writes `%{invocation | exports:
  ...}` like it would write `environment`.
- `source/lib/bates/middleware/registry.ex` — has `register/2` and
  `unregister/1` already, gated by `if Mix.env() == :test`. Use these
  for stubs.
- `source/lib/bates/app.ex` — the runtime home for everything in this
  plan.

**Existing test patterns to follow:**

- `source/test/bates/middleware_test.exs` already has inline `defmodule
  StubMiddleware` and `defmodule PrologueA/B` modules implementing the
  behaviour. The new `test/support/` stubs follow the same pattern but
  live in their own files for reuse.
- The "Registry.register/2 (test-only)" describe block in
  `middleware_test.exs` shows the `Registry.register("name", Module)` +
  `on_exit(fn -> Registry.unregister("name") end)` idiom.
- PR #23's `multi_service_with_deps_*` helpers in `app_test.exs` (or
  wherever they ended up) are the closest fixture pattern for a
  producer/consumer layout. The test for the loading-controller
  upstream-crash scenario used `command = "exit 1"` for deterministic
  immediate crash — same pattern works for the crash-clearing test
  here.

**Mix.exs:**

- `source/mix.exs` already has
  `defp elixirc_paths(:test), do: ["lib", "test/support"]`. The new
  stub modules under `source/test/support/` will be compiled in test
  env automatically. No mix.exs changes needed.

**Spec:**

- `specs/process-management.md`, "Service Environment Exports" section
  (around line 257) and "Process Invocation" table (around line 244)
  describe the design. Reading these first will ground the
  implementation.

---

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-04-29 | READY FOR AUTONOMOUS EXECUTION | Subagent verified all paths and dependencies. Found one correctness bug in Phase 3's merge order (topsort direction); fixed by adding `Enum.reverse/1` step. No blockers. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

All structural requirements met. Codebase has the necessary OTP
dependencies (`:digraph`, `:digraph_utils`), test infrastructure
(`source/test/support/` already in `elixirc_paths(:test)`,
`Bates.Middleware.Registry.register/2` already exposed for tests), and
existing patterns (the `multi_service_with_deps_config` fixture in
`source/test/bates/app_test.exs` line 210 is reusable). One semantic
issue surfaced — `:digraph_utils.topsort/1` walks dependents-first with
the existing edge direction, which would have inverted the merge
priority — has been corrected in Phase 3 and the corresponding
acceptance criterion.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| Accepted proposal | Ready | `workflow/proposals/accepted/2026-04-29-cross-service-environment-exports.md` |
| `multi_service_with_deps_config` fixture | Ready | `source/test/bates/app_test.exs:210` (web depends on vite) |
| `source/test/support/` in `elixirc_paths(:test)` | Ready | `source/mix.exs:23` |
| `Bates.Middleware.Registry.register/2` | Ready | `source/lib/bates/middleware/registry.ex:29-32`, gated by `Mix.env() == :test` |
| Existing test-helpers module | Ready | `source/test/support/test_helpers.ex` |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `:digraph` (OTP) | Available | Already used at `source/lib/bates/app.ex:251` |
| `:digraph_utils` (OTP) | Available | Already used at `source/lib/bates/app.ex:265` |
| `Phoenix.PubSub` | Installed | `source/mix.exs:32` |
| `:erlexec` | Installed | `source/mix.exs:30` |

### Open Questions

| # | Question | Blocking? | Notes |
|---|----------|-----------|-------|
| 1 | `:digraph_utils.topsort/1` direction with `dependent → dependency` edges | Resolved (was blocking) | Returns dependents-first, confirmed by the existing `reverse_topological_order/1` naming and the spec's "Stopping an app reverses the order — dependents stop before their dependencies" semantic. Phase 3 now reverses the filtered topsort before folding. |
| 2 | `:digraph_utils.reachable/2` direction | Resolved | `reachable([V], G)` follows outgoing edges. With edges `dependent → dependency`, the closure of A is A's dependencies (transitive). Matches plan's intent. |
| 3 | `Map.merge/2` override semantics | Resolved | `Map.merge(a, b)` makes b's keys win over a's. Standard Elixir, used the same way elsewhere in `Bates.App`. |
| 4 | Test stub strategy: one module or two? | Non-blocking | Author's choice. Existing `middleware_test.exs` pattern uses multiple inline modules per behaviour; the agent should follow that pattern for new stubs in `test/support/`. |

### POC Gaps

| # | Assumption | Status |
|---|-----------|--------|
| 1 | `:digraph_utils.reachable/2` returns the dependency closure when edges point dependent → dependency. | Confirmed via OTP semantics and the existing graph shape in `app.ex`. |
| 2 | `:digraph_utils.topsort/1` returns dependencies before dependents. | **Denied.** Existing helper is named `reverse_topological_order` precisely because topsort gives dependents-first. Plan corrected: closure is filtered from topsort output then **reversed** before folding. |
| 3 | `Map.merge(acc, dep_exports)` makes `dep_exports` override `acc`. | Confirmed. Standard Elixir; combined with the (now reversed) walk order, direct deps overwrite transitive deps. |

### Pre-Work

None. The plan is ready as-is following the Phase 3 correction.

### Blockers

None identified.

---

## Execution Notes

- **Test fixture had to use port-bearing producers, not portless.** My
  initial draft of `producer/consumer` test fixtures used portless
  services (`hostname: nil, port: nil, middleware: ["export_producer"]`).
  Those failed because portless services in `start_service/3` go to
  `up` immediately but never call `start_eligible/1`, so a downstream
  consumer that `depends_on` a portless producer never gets started.
  This is a pre-existing limitation of the depends-on/portless
  combination and out of scope here. Switched the fixtures to
  port-bearing services with `middleware: ["port", "export_producer"]`
  using `test/support/test_server.ex` as the command — the readiness
  check then drives `start_eligible/1` and consumers come up. All
  exports tests now pass.

- **Inspecting `exports` in tests.** No public API exposes per-service
  `exports`. Used `:sys.get_state/1` against the `App` GenServer pid
  (resolved via `GenServer.whereis({:via, Registry, {Bates.ProcessRegistry,
  app_name}})`) to read `state.services[name].exports` for the
  "exports clear after down/crash" assertions and the producer
  persistence assertion. Avoided adding a public API just for tests.

- **Three stub middleware modules instead of one.** The plan suggested
  one parameterized module would be acceptable; settled on three
  small, single-purpose modules (`ExportProducer`,
  `EnvironmentRecorder`, `EnvironmentOverride`) keyed by service name
  via the `:bates` application env. Mirrors the existing
  `MarkerMiddleware` pattern in `app_test.exs`.

- **Recorder asserts specific keys, not full equality.** The
  port-bearing producers feed `PORT` into the consumer's environment
  too, so the `EnvironmentRecorder` snapshot is asserted with
  per-key reads (`recorded_env("consumer")["DATABASE_URL"]`) rather
  than `==` against an expected map.

- **No spec edits.** Spec already documents the design accurately.

- **No mix.exs changes.** `test/support/` was already in
  `elixirc_paths(:test)` from prior work.

- **mix format touched unrelated files.** Running `mix format` on the
  whole tree reformatted several pre-existing files that are not in
  scope for this plan (caddy.ex, router.ex, controllers, etc.). I
  reverted those and committed only the format tweaks to files this
  branch already touched.

### Execution Stats

| Metric | Value |
|--------|-------|
| Duration | ~16m |
| Commits | 7 |
| Files changed | 6 |
| Tests added | 12 |
| PR | #24 |
