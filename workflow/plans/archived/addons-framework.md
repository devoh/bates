# Plan: Addons Framework

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-04-30 | Plan created from accepted proposal. |
| 2026-04-30 | Readiness audit completed. Verdict: READY FOR AUTONOMOUS EXECUTION. No plan changes required; three executor notes recorded under Recommended Plan Changes. |

## Goal

Wire the addons framework into the configuration loader: parse `addons`
declarations on application tables (short and table forms), expand each
declared addon into a regular `%Service{}` entry, and append an implicit
`depends_on` edge from every non-addon service to each addon. Ship the
new `Bates.Addon.Registry` module behind which concrete addons (#20)
will register.

## Proposal

`workflow/proposals/accepted/2026-04-30-addons-framework.md`

## Why This Matters

The spec already documents addons as the user-facing surface that ties
`depends_on` (#16, shipped) and cross-service exports (#18, shipped)
together. Until the framework exists, every application has to declare
its database (or Redis, or other shared dependency) as a hand-rolled
service with hand-wired environment plumbing — exactly the boilerplate
those two systems were built to remove. The `postgresql` addon (#20)
also has nothing to plug into until this lands.

## Acceptance Criteria

- [x] `Bates.Addon.Registry` module exists at
      `source/lib/bates/addon/registry.ex`. Public API: `lookup/1`
      returning `{:ok, definition} | {:error, :unknown}`, `lookup!/1`
      returning the definition or raising. Test-gated `register/2` and
      `unregister/1` matching the `Bates.Middleware.Registry` pattern
      (gated by `if Mix.env() == :test`).
- [x] Definition shape is `%{command: String.t(), middleware:
      [String.t()]}`. The `middleware` key defaults to `[addon_name]`
      when the registered map omits it.
- [x] Production registry holds zero entries (`@builtins %{}`).
- [x] `Bates.Config.applications/1` recognizes `addons` as an
      application-level field. Both forms decode to the same internal
      list of addon names:
      - Short form: `addons = ["postgresql", "redis"]` preserves
        declared order.
      - Table form: `[myapp.addons.postgresql]` and
        `[myapp.addons.redis]` produces names sorted alphabetically
        (TOML decoders do not guarantee table key order; alphabetical
        is stable across runs).
- [x] Each declared addon expands into a `%Bates.Service{}` with:
      - `name = addon_name`
      - `command = definition.command`
      - `port = nil`
      - `hostname = nil`
      - `middleware = app_middleware ++ definition.middleware`
      - `depends_on = []`
- [x] For every non-addon service `s` in the application, each addon
      name is appended to `s.depends_on` in the order described above.
      Existing user-declared entries are preserved; an addon name
      already present (unlikely, but possible) is not duplicated.
- [x] Sibling addon services do not receive implicit edges to other
      addon services.
- [x] Single-service shorthand combined with `addons` produces a
      multi-service application with both the shorthand-derived
      service and the addon services. The shorthand-derived service
      carries the implicit edge to each addon.
- [x] `addons = []` is a valid no-op: no expansion, no implicit edges,
      no errors.
- [x] `Bates.Config.applications/1` returns
      `{:error, {:unknown_addon, app_name, addon_name}}` when an addon
      name is not registered.
- [x] `Bates.Config.applications/1` returns
      `{:error, {:addon_name_collision, app_name, addon_name}}` when
      an addon name matches a user-declared service in the same
      application.
- [x] `Bates.Config.applications/1` returns
      `{:error, {:duplicate_addon, app_name, addon_name}}` when the
      short form lists the same name twice. (TOML's parser rejects the
      table-form duplicate path before Bates sees it, so no Bates code
      is needed for that case.)
- [x] The loader's `with` chain runs in the order:
      `build services → expand_addons → validate_middleware →
      validate_dependencies`. The `expand_addons` step produces the
      three errors above and emits the expanded service list with
      implicit edges baked in. Downstream validators run on that
      expanded list unchanged.
- [x] `source/test/bates/addon/registry_test.exs` exists, covering
      `lookup`, `lookup!`, `register`/`unregister` round-trip, and the
      `middleware` default.
- [x] `source/test/bates/config_test.exs` gains a `describe "addons"`
      block with cases enumerated in the issue plus the empty-list
      case.
- [x] New TOML fixtures under `source/test/fixtures/`, one per shape
      tested (see Phase 3 for the list).
- [x] `specs/process-management.md` Addons section documents:
      app-level middleware applies to addons; single-service shorthand
      + addons silently expands; empty `addons = []` is valid;
      implicit-edge ordering rule.
- [x] `mix format` is clean for files this branch touched.
- [x] All existing tests still pass.

## Phases

### Phase 1: `Bates.Addon.Registry` module

Self-contained unit. Defines the registry interface that Phase 2
consumes; verifiable in isolation.

**Files:**

- `source/lib/bates/addon/registry.ex` (new) — module mirroring
  `source/lib/bates/middleware/registry.ex`. Production `@builtins` is
  `%{}`. `lookup/1` returns `{:ok, definition} | {:error, :unknown}`.
  `lookup!/1` returns the definition or raises with a "known: ..."
  message (empty list is fine — the runtime path is exercised by
  test-registered stubs only). Definition normalization happens in
  the registry: when a registered map omits `:middleware`, the
  registry fills in `[name]`.

  Sketch:

  ```elixir
  defmodule Bates.Addon.Registry do
    @builtins %{}

    def lookup(name) when is_binary(name) do
      case Map.fetch(all(), name) do
        {:ok, definition} -> {:ok, normalize(name, definition)}
        :error -> {:error, :unknown}
      end
    end

    def lookup!(name) when is_binary(name) do
      case lookup(name) do
        {:ok, definition} ->
          definition

        {:error, :unknown} ->
          known = all() |> Map.keys() |> Enum.sort() |> Enum.join(", ")
          raise "Unknown addon: #{inspect(name)} (known: #{known})"
      end
    end

    defp normalize(name, definition) do
      Map.put_new(definition, :middleware, [name])
    end

    if Mix.env() == :test do
      @extra_key :extra_addons

      def register(name, definition) when is_binary(name) and is_map(definition) do
        extra = Application.get_env(:bates, @extra_key, %{})
        Application.put_env(:bates, @extra_key, Map.put(extra, name, definition))
        :ok
      end

      def unregister(name) when is_binary(name) do
        extra = Application.get_env(:bates, @extra_key, %{})
        Application.put_env(:bates, @extra_key, Map.delete(extra, name))
        :ok
      end

      defp all do
        extra = Application.get_env(:bates, @extra_key, %{})
        Map.merge(@builtins, extra)
      end
    else
      defp all, do: @builtins
    end
  end
  ```

- `source/test/bates/addon/registry_test.exs` (new) — tests:
  - `lookup/1` on an unregistered name returns `{:error, :unknown}`.
  - After `register("foo", %{command: "bar"})`, `lookup/1` returns
    `{:ok, %{command: "bar", middleware: ["foo"]}}` (default applied).
  - Registering with explicit `middleware: ["asdf", "foo"]` preserves
    the list verbatim.
  - `unregister/1` reverses `register/1`.
  - `lookup!/1` raises on unknown name with a helpful message.

**Why grouped:** the module has no dependencies on any other change.
Landing it first means Phase 2 has a stable surface to build against.

### Phase 2: Addon expansion in `Bates.Config`

The core behavior change. Adds parsing, expansion, implicit edges, and
the three new validation variants in one cohesive change because they
are tightly coupled (the expansion produces both the new service list
and the validation errors).

**Files:**

- `source/lib/bates/config.ex` — extend `build_application/1` and the
  top-level `applications/1` pipeline.

  1. Pull `addons` out of the application's options alongside
     `middleware`. Normalize:
     - If the value is a list of strings: keep as-is (declared order).
     - If the value is a map (table form): take `Map.keys/1`, sort
       alphabetically. (The table form values are ignored in v1; no
       addon defines override fields.)
     - If absent or `[]`: empty list, no expansion happens.
  2. Build the user-declared services as today
     (`build_single_service/4` or `build_multi_services/3`).
  3. Run a new private function `expand_addons(app_name, services,
     addon_names, app_middleware)` that:
     - Detects duplicate names within the addon list (only possible
       in the short form; sorted table-form keys are unique by
       construction). Returns
       `{:error, {:duplicate_addon, app_name, name}}` on the first
       duplicate.
     - Detects collision between any addon name and a user-declared
       service name. Returns
       `{:error, {:addon_name_collision, app_name, name}}`.
     - For each addon name, calls `Bates.Addon.Registry.lookup/1`.
       Returns `{:error, {:unknown_addon, app_name, name}}` on the
       first unknown.
     - Builds a `%Service{}` per addon (see acceptance criteria for
       the field values). Note that `app_middleware ++
       definition.middleware` is the new service's middleware list;
       the existing `merge_middleware/3` "auto-append `port`" rule
       does not apply (addon services have no hostname).
     - Appends each addon name to every non-addon service's
       `depends_on`, in the addon-list order. Skip if the addon name
       is already present in `depends_on` (idempotent).
     - Returns `{:ok, expanded_services}` where `expanded_services`
       is `services_with_updated_depends_on ++ addon_services`.
  4. `build_application/1` returns `{name, root, expanded_services}`
     on success or propagates the `{:error, _}` tuple.
  5. The top-level `applications/1` pipeline becomes:
     ```elixir
     with {:ok, applications} <- build_applications(config),
          :ok <- validate_middleware(applications),
          :ok <- validate_dependencies(applications) do
       applications
     end
     ```
     where `build_applications/1` is a thin wrapper that maps
     `build_application/1` over the config and short-circuits on the
     first `{:error, _}`.

  The existing `build_application/1` returns a bare tuple today
  (`{name, root, services}`). It needs to change to return
  `{:ok, tuple} | {:error, reason}` so addon errors can flow up
  through `with`. The map-and-check pattern in
  `Enum.reduce_while/3` is the idiomatic way; alternatively a
  `with`-chain at the top level. Keep whichever feels cleanest in
  context — the existing `validate_*` functions already use
  `Enum.reduce_while/3` and that pattern transplants well.

  Touchpoints to be careful about:
  - `merge_middleware/3` currently appends `"port"` automatically
    when the service has a hostname. Addon services have
    `hostname: nil`, so the rule doesn't fire — `merge_middleware`
    is *not* the right helper for addon services. Inline the
    `app_middleware ++ definition.middleware` concat directly in
    `expand_addons`.
  - `build_single_service/4` does not pass `depends_on` (single
    services have no dependencies today). After expansion, that
    service may have non-empty `depends_on` for the first time.
    Confirm the `%Service{}` struct accepts a non-empty
    `depends_on` from the shorthand path (it does — the field has a
    default of `[]`).

**Why grouped:** parsing, expansion, implicit-edge insertion, and
validation are intrinsic to the same code change. Splitting them
would require feature-flag-style intermediate states. Cohesive
single-purpose change is easier to review.

### Phase 3: Test fixtures + `Bates.Config` test cases

Round out behavior coverage. Tests live separately from Phase 2
because they need stub addons registered via `Bates.Addon.Registry`.

**Files:**

- `source/test/fixtures/addons_short_form_config.toml` (new) — single
  app with `addons = ["sidekick"]` and a couple of user-declared
  services. Fixture uses a stub addon name (`sidekick` or similar) so
  it's clearly not aspirationally tied to #20's `postgresql`.

- `source/test/fixtures/addons_table_form_config.toml` (new) — same
  setup using `[myapp.addons.sidekick]`.

- `source/test/fixtures/addons_collision_config.toml` (new) — declares
  an addon name (`sidekick`) that also appears as a user-declared
  service in the same application.

- `source/test/fixtures/addons_unknown_config.toml` (new) — declares
  an addon name with no registered definition.

- `source/test/fixtures/addons_duplicate_config.toml` (new) —
  short-form list with the same addon name twice.

- `source/test/fixtures/addons_with_existing_depends_on_config.toml`
  (new) — addon plus a user service that already declares its own
  `depends_on`. Verifies preservation.

- `source/test/fixtures/addons_single_service_shorthand_config.toml`
  (new) — `command = "..."` shorthand plus `addons = ["sidekick"]`.
  Verifies silent expansion to multi-service.

- `source/test/fixtures/addons_empty_list_config.toml` (new) —
  `addons = []`. Verifies no-op behavior.

- `source/test/bates/config_test.exs` — add a `describe "addons"`
  block following the patterns established by the existing
  `describe "middleware"` and `describe "depends_on"` blocks. Use
  `setup` to register the stub addon(s) via
  `Bates.Addon.Registry.register/2` and `on_exit` to unregister.

  Tests (one per acceptance criterion in the issue, plus extras):
  - Both short and table forms produce identical service maps.
  - Implicit dependency edge appears on every non-addon service.
  - Implicit edge is *not* added between sibling addons.
  - Unknown addon name returns `{:error, {:unknown_addon, app, name}}`.
  - Addon-name collision with user service returns
    `{:error, {:addon_name_collision, app, name}}`.
  - Duplicate addon in short form returns
    `{:error, {:duplicate_addon, app, name}}`.
  - Existing `depends_on` entries on a user service are preserved
    alongside the appended addon edge.
  - Single-service shorthand + addons silently expands; the
    shorthand-derived service has the implicit edge.
  - `addons = []` produces the same service list as the no-`addons`
    case (a control fixture or just inline assertion).
  - Stub addon's `command` flows into the expanded service's
    `command`.
  - `app_middleware ++ definition.middleware` is the expanded
    service's middleware list (test with an app-level `middleware =
    ["asdf"]` and a stub addon whose definition uses the default
    `[addon_name]` middleware list — assert the expansion is
    `["asdf", addon_name]`).

  Two stub addons are useful: one with default middleware
  (`%{command: "..."}`) and one with explicit
  `middleware: ["asdf", "stub2"]` to cover the override path. Author
  may collapse into fewer stubs if cleaner.

**Why grouped:** fixtures and tests are complementary. Adding them
together keeps the test surface coherent and lets the agent verify
each acceptance criterion against a concrete fixture.

### Phase 4: Spec addendum + format + final test

Standard wrap-up.

**Files:**

- `specs/process-management.md` — extend the Addons section to
  document the four behaviors decided in refinement that aren't in
  the spec today:
  1. Application-level middleware applies to expanded addon services.
     The expanded service's middleware list is `app_middleware ++
     addon_definition.middleware`. Preferred location: a sentence in
     the **Expansion** subsection (around line 353), or its own
     subsection if it grows beyond a sentence.
  2. Single-service shorthand combined with `addons = [...]` silently
     expands to multi-service. The shorthand-derived service receives
     the implicit edge. Preferred location: a sentence in the
     **Declaring Addons** subsection.
  3. `addons = []` is a valid no-op. Preferred location: same
     subsection.
  4. Implicit-edge ordering: short form preserves declared TOML
     order; table form uses alphabetical order. Preferred location:
     **Implicit Dependency Edge** subsection.

  Keep the additions concise; the spec already covers the framework
  at a high level. These are clarifications, not a rewrite.

- Run `mix format` on every file this branch touched. Do not
  reformat unrelated files (`cross-service-environment-exports.md`'s
  Execution Notes flagged this same trap — `mix format` on the whole
  tree historically pulls in unrelated diffs that should be reverted).

- Run the full `mix test` and confirm green.

**Why grouped:** standard wrap-up — spec sync, format, full test
suite.

## What Does NOT Change

- No concrete addon implementation (e.g., `postgresql`). The
  `@builtins` map in `Bates.Addon.Registry` ships empty. (#20)
- No user-defined addon registration outside the test environment.
- No multi-instance addon support.
- No per-service opt-out flag from the implicit dependency edge.
- No dashboard differentiation between addon and user services.
- No changes to `Bates.App`. The runtime sees an addon as a regular
  service — the framework's payoff is precisely that no runtime code
  needs to change.
- No changes to `Bates.Service` struct fields. The existing struct
  accepts the addon-expanded shape unchanged.
- No changes to existing middleware modules or the
  `Bates.Middleware.Registry`.
- The `port` middleware's auto-append rule (fires only when
  `hostname != nil`) is unchanged. Addon services have no hostname,
  so the rule is correctly inert for them.
- No spec rewrite — only the four-point addendum to the Addons
  section.

## Where to Start

> These are pointers from the codebase survey at plan creation time.
> Files may have changed by execution time. Verify before acting.

**Core flow to trace:**

The change is concentrated in the configuration loader. Read
`source/lib/bates/config.ex` end-to-end first; everything else is
context. The `Config.applications/1` function (line 6) is the
top-level entry. Today its `with` chain has two validation steps;
the new pipeline inserts addon expansion between `build` and the
existing validators.

`build_application/1` (line 21) currently returns a bare
`{name, root, services}` tuple. The plan changes this to return
`{:ok, tuple} | {:error, reason}` so addon errors can short-circuit
through `with`. The pattern used by `validate_dependencies/1` (line
117) — `Enum.reduce_while/3` returning the first error — is the
established idiom.

**Key files and what's in them:**

- `source/lib/bates/config.ex` — the only production file that
  changes. Look at how `merge_middleware/3` (line 69) handles the
  `port` auto-append rule; addon services bypass that helper because
  they have no hostname.
- `source/lib/bates/service.ex` — `%Service{}` struct (line 1).
  No changes needed; the existing fields support the addon-expanded
  shape.
- `source/lib/bates/middleware/registry.ex` — the template for
  `Bates.Addon.Registry`. Same module shape, same test-gating
  pattern. Especially note the `if Mix.env() == :test` block
  (line 26) — the new addon registry mirrors this verbatim with
  different defaults.

**Existing test patterns to follow:**

- `source/test/bates/config_test.exs` — `describe "middleware"`
  (line 78) and `describe "depends_on"` (line 147) are the
  established models. Follow the same fixture-per-shape style. The
  unknown-name test cases (line 141, 174) show the
  `{:error, {tag, ...}}` assertion pattern the new addon validation
  errors should follow.
- `source/test/bates/middleware/asdf_test.exs` (and sibling
  middleware tests) — pattern for testing a registry-backed module.
- The test-gated `Bates.Middleware.Registry.register/2` is used in
  `source/test/bates/middleware_test.exs` (per the
  cross-service-environment-exports plan's Execution Notes); use the
  same `setup`/`on_exit` pattern for `Bates.Addon.Registry.register/2`.

**Fixture patterns:**

- `source/test/fixtures/middleware_config.toml` and
  `source/test/fixtures/multi_service_with_deps_config.toml` are the
  closest existing fixtures. Both define a single application with
  multiple services; the addon fixtures follow the same style with
  an additional `addons = [...]` line at the application level (or a
  `[myapp.addons.<name>]` block).

**Mix.exs:**

- `source/mix.exs` already has
  `defp elixirc_paths(:test), do: ["lib", "test/support"]`. No
  changes needed for this plan since stubs live in the test files
  themselves (no `test/support/` modules required, unlike the
  exports plan).

**Spec:**

- `specs/process-management.md` lines 299–391 cover Addons today.
  The four-point addendum from Phase 4 attaches to the existing
  subsections (Declaring Addons, Expansion, Implicit Dependency
  Edge). Read the full Addons section before editing so the
  additions match the existing voice and structure.

**Outside this plan but relevant:**

- The `postgresql` addon (#20) is the first consumer. Decisions
  here should not over-constrain that work; the registry's
  `definition` shape (`%{command, middleware}`) is intentionally
  small to leave room.
- The cross-service-environment-exports plan's Execution Notes
  (in the corresponding archived plan file) flagged a `mix format`
  pitfall — running it on the whole tree pulls in unrelated diffs.
  Same caution applies here: format only the touched files.

---

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-04-30 | READY FOR AUTONOMOUS EXECUTION | Subagent verified all dependencies (#16 and #18 merged, registry pattern usable, `Bates.Service` accepts addon-expanded shape), confirmed TOML decode behavior matches the existing services pattern, and reviewed cross-spec impact (no other specs need updating). No blockers. No open questions requiring human input. Three minor executor notes recorded but no plan changes required. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

The plan is well-scoped, all upstream dependencies are merged, the
`Bates.Middleware.Registry` template is proven reusable, and the
spec-update step is targeted at the right section. `/execute-plan` can
proceed.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| `source/test/fixtures/middleware_config.toml` | Ready | Existing template for app-level middleware fixtures. |
| `source/test/fixtures/multi_service_with_deps_config.toml` | Ready | Existing template for multi-service + `depends_on` shape. |
| `source/test/fixtures/` directory | Ready | 10 existing TOML fixtures; new ones drop in alongside. |
| Stub-addon registration pattern | Ready | `source/test/bates/middleware_test.exs` lines 48–72 show the `register/unregister` + `on_exit` cleanup idiom. New addon registry mirrors verbatim. |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| #16 service dependency ordering | Shipped | `Bates.App` has `depends_on` handling at `source/lib/bates/app.ex:269,291`. |
| #18 cross-service environment exports | Shipped | `ProcessInvocation.exports` field present at `source/lib/bates/process_invocation.ex:3,8`. |
| `Bates.Service` struct shape | Ready | `source/lib/bates/service.ex:3-9` — `depends_on: []` default; accepts non-empty values. |
| `Bates.Middleware.Registry` template | Ready | `source/lib/bates/middleware/registry.ex:1-48` — `lookup/1`, `lookup!/1`, test-gated `register/2`/`unregister/1` via `if Mix.env() == :test`. |
| `Toml.decode/1` short vs. table form | Ready | Existing `[myapp.services.web]` pattern in `multi_service_config.toml` already exercises the table-form-as-map decode that addons reuse. |
| `Mix.env() == :test` gating | Ready | Used by the middleware registry; same pattern transplants. |
| New Hex deps | None needed | Plan uses only `Toml`, `Map`, `Enum`, and existing Bates modules. |

### Open Questions

| # | Question | Blocking? | Notes |
|---|----------|-----------|-------|
| 1 | Where does `expand_addons` run — inside `build_application/1` or as a separate top-level pass? | Resolved | Plan Phase 2 calls it from `build_application/1`, which now returns `{:ok, tuple} | {:error, reason}`. The top-level `with` chain becomes `with {:ok, apps} <- build_applications/1, :ok <- validate_middleware, :ok <- validate_dependencies`. Unambiguous. |
| 2 | Does middleware-list normalization happen in `lookup/1` or `register/2`? | Resolved | Plan Phase 1 specifies `lookup/1` does the normalization (registered map's `:middleware` defaults to `[name]` at lookup time). Sketch in plan confirms. |
| 3 | `expand_addons/4` argument order? | Resolved | Plan Phase 2 specifies `expand_addons(app_name, services, addon_names, app_middleware) :: {:ok, services} | {:error, reason}`. Unambiguous. |

### POC Gaps

| # | Assumption | Resolution | Effort |
|---|------------|------------|--------|
| 1 | Short form `addons = [...]` decodes to a list; table form `[myapp.addons.<name>]` decodes to a map. | Confirmed by analogy with the existing services decode in `Bates.Config.build_multi_services/3` (`source/lib/bates/config.ex:48`), which iterates the table-form services map. The exact same `Toml.decode/1` produces the same shape for any TOML table — addons reuse the proven path. | Resolved by code reading; no live POC needed. |
| 2 | `merge_middleware/3` does not collide with addon services (which bypass it). | Confirmed at `source/lib/bates/config.ex:69-77`: the auto-`port` append fires only when `hostname != nil`. Addon services have `hostname: nil`, so the rule is correctly inert. The plan inlines `app_middleware ++ definition.middleware` rather than calling `merge_middleware/3`. | Resolved by code reading. |
| 3 | TOML decoders don't preserve table-key order (motivating the alphabetical sort for the table form). | Standard TOML semantics. The plan handles this by sorting `Map.keys/1` alphabetically for the table form. | Resolved by spec. |

### Pre-Work

None. The plan can be executed as written.

### Blockers

None identified.

### Recommended Plan Changes (non-blocking executor notes)

The audit found no required changes, but flagged three quality-of-life
notes for the executor:

1. **Phase 2 wrapper helper.** The plan describes a `build_applications/1`
   wrapper that maps `build_application/1` and short-circuits on the
   first `{:error, _}`. The sketch doesn't name it explicitly. The
   executor should pick a name consistent with the existing
   `validate_*` helpers — `Enum.reduce_while/3` is the established
   short-circuit idiom in `source/lib/bates/config.ex:90,118`.
2. **Test fixture grouping.** Eight new fixtures live under
   `source/test/fixtures/`. Consider a brief comment or naming
   convention so it's obvious which fixture exercises which behavior
   (especially the four error-path fixtures: collision, unknown,
   duplicate, plus the two happy-path forms). Pure ergonomics.
3. **Format only touched files.** Confirmed once already — the
   cross-service-environment-exports plan's execution notes warn that
   `mix format` on the whole tree pulls in unrelated diffs. Format
   only the files this branch touched.

---

## Execution Notes

- The plan landed exactly as designed. No deviations from the four-phase
  structure, no changes to the three new error tags, no surprises in
  `Toml.decode/1` behavior for short-vs-table forms.
- Stub-middleware coupling: the addon registry's `middleware` default of
  `[addon_name]` means a stub addon registered as
  `Bates.Addon.Registry.register("sidekick", %{command: "..."})` produces
  an expanded service whose middleware list contains `"sidekick"`. The
  existing `validate_middleware/1` step then tries to resolve that name
  in `Bates.Middleware.Registry` and fails. The `setup` block in
  `describe "addons"` therefore registers a stub `sidekick` middleware
  alongside the addon. Worth flagging for #20: the `postgresql` addon's
  registered middleware name(s) must already be registered in
  `Bates.Middleware.Registry` for the loader to accept the expansion.
- One fixture was added beyond the plan's eight:
  `addons_with_app_middleware_config.toml`. It pairs `middleware =
  ["asdf"]` with an addon to assert
  `app_middleware ++ definition.middleware` concretely. Pure ergonomics.
- Two test cases (sibling-addon implicit-edge isolation and
  explicit-middleware override) write inline TOML to `System.tmp_dir!/0`
  and clean up via `on_exit`. Same shape as the rest of the suite,
  avoids creating fixture files for one-off shapes.
- `build_applications/1` uses `Enum.reduce_while/3` with an
  `acc ++ [application]` accumulator to preserve declared application
  order. The list is small enough that O(n^2) append cost is irrelevant;
  matches the readability of the `validate_*` helpers.
- Spec addendum lives next to the existing prose in three subsections
  (Declaring Addons, Expansion, Implicit Dependency Edge), keeping the
  existing voice. No section restructuring.

### Execution Stats

| Metric | Value |
|--------|-------|
| Duration | ~9m |
| Commits | 4 |
| Files changed | 14 |
| Tests added | 2 (1 new test file, 1 describe block in existing) |
| PR | TBD |
