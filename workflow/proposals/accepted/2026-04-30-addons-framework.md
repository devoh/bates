# Addons Framework — Proposal

**Status:** Accepted
**Date:** 2026-04-29
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/19
**Synced:** 2026-04-29 (no comments on issue)
**Refined:** 2026-04-30

## Summary

Wire the addons framework specified in `specs/process-management.md`
into the configuration loader. An application declares addons by name
(`addons = ["postgresql"]`); at config-load time each addon expands
into a regular service entry whose middleware list is the addon's
built-in middleware, and every non-addon service in the application
gains an implicit `depends_on` edge to it. This issue covers the
framework only — no concrete addon implementation ships with it.

---

## Problem

The spec already describes a `postgresql` addon that publishes `PGPORT`
to dependents, but nothing in the loader recognizes the `addons` field
on an application table. Until the framework exists, every application
has to declare its database (or Redis, or other shared dependency) as a
hand-rolled service with hand-wired environment plumbing — exactly the
boilerplate cross-service exports (#18) and dependency ordering (#16)
were built to remove. The addons framework is the user-facing surface
that ties those two systems together.

A second motivation: the upcoming `postgresql` addon (#20) needs
somewhere to plug into. Without the framework, that work has nothing to
attach a middleware and a service definition to.

---

## Decided

The mechanics are settled in `specs/process-management.md` (Addons —
Declaring Addons, Available Addons, Expansion, Implicit Dependency
Edge, Addons and Exports). The issue restates them as the work
contract; no decisions are being re-litigated.

**Declaration syntax:**

- Short form: `addons = ["postgresql"]` on the application table.
- Table form: `[myapp.addons.postgresql]` (empty body in v1, since no
  addon defines override fields).
- The two forms produce identical configurations.

**Expansion:**

- Each declared addon expands into a `%Service{}` entry in the
  application's service map at config-load time.
- The service name matches the addon name (`postgresql` → service
  named `postgresql`).
- The expanded service's `middleware` list contains a built-in
  middleware of the same name. The addon implementation (the follow-up
  issue) provides that middleware; this issue only wires the
  expansion.
- An addon expanded service is otherwise a regular service from the
  runtime's perspective: status, log buffer, dashboard row,
  start/stop participation.

**Implicit dependency edge:**

- Every non-addon service in the application gains
  `addon_name` appended to its `depends_on` list. Existing
  user-declared `depends_on` entries are preserved; the addon edge is
  appended.
- Addon services do *not* get implicit edges to sibling addons. The
  issue's test list is explicit: "Implicit dependency edge appears on
  every non-addon service."

**Validation (all surfaced by the configuration loader before any
application is supervised, matching today's `unknown_middleware` /
`unknown_dependency` paths):**

- Unknown addon name → reject.
- Addon name collides with a user-declared service in the same
  application → reject.
- Same addon declared twice in the same application → reject.

**v1 scope guards (per issue "Out of scope"):**

- Built-in addons only. No user-defined addons.
- One instance per addon per application.
- No per-service opt-out flag. The opt-out is "do not declare it as an
  addon."
- Dashboard treats addon services as regular service rows. No visual
  distinction in this issue.
- The `postgresql` addon itself ships separately (#20).

**Refinement decisions (2026-04-30):**

- **Registry split.** A new `Bates.Addon.Registry` module mirrors
  `Bates.Middleware.Registry`'s API (`lookup/1`, `lookup!/1`,
  test-gated `register/2`). Addons are not middleware and need a
  separate definition shape.
- **Addon definition shape.** `%{command: String.t(), middleware:
  [String.t()]}`. The `middleware` field is a *list*, defaulting to
  `[addon_name]`. Typed as a list so future addons can compose
  (e.g., a routable addon that needs `["port", addon_name]`).
- **Empty registry in production.** Acceptable. The registry has zero
  entries until #20 ships; any production `addons = [...]` declaration
  fails the `unknown_addon` check with a clear error. Tests register a
  stub via `register/2`.
- **App-level middleware applies to expanded addon services.** The
  expanded service's final middleware list is
  `app_middleware ++ addon_definition.middleware`. Driven by the
  per-app runtime case (e.g., `.tool-versions` declaring a Postgres
  version that asdf must resolve before the addon's command can find
  the binary). Matches the spec's existing "applies to all services"
  rule, so no special case in the expansion code.
- **Single-service shorthand + addons silently expands.** An app with
  `command = "..."` plus `addons = [...]` becomes a multi-service
  app after expansion. The shorthand-derived service still gets the
  implicit edge to each addon. No special syntax required from the
  user.
- **Validation pipeline.** `Config.applications/1`'s `with` chain
  becomes `build services → expand_addons → validate_middleware →
  validate_dependencies`. `expand_addons` returns the three new error
  variants (`unknown_addon`, `addon_name_collision`, `duplicate_addon`)
  before producing the expanded service list with implicit edges
  baked in. Existing validators run unchanged on the expanded list.
- **Duplicate detection scope.** TOML rejects the short-form +
  table-form combination at parse time (a key cannot be both an array
  and a table). Bates only needs to detect the in-list short-form
  duplicate (`addons = ["postgresql", "postgresql"]`); table-form
  duplicates are impossible because TOML keys are unique.
- **Empty `addons = []`.** Valid no-op. No expansion, no implicit
  edges, no error. Confirmed by a test.
- **Implicit-edge ordering.** Short form preserves the declared TOML
  order when appending addon names to a service's `depends_on`. Table
  form falls back to alphabetical order (TOML decoders don't preserve
  table key order; alphabetical is stable across runs). Documented in
  the spec. Runtime semantics are set-like; ordering matters only for
  test stability and reproducible error messages.
- **Spec updates ship with the PR.** `specs/process-management.md`
  Addons section gains a short addendum covering the four points
  above that aren't in the spec today (app-level middleware
  application, single-service shorthand interaction, empty list
  no-op, edge ordering rule).

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted
> or executed. These are pointers to help orient, not implementation
> instructions.

**Configuration loader:** `source/lib/bates/config.ex` —
`build_application/1` peels a single application's TOML table apart.
Today it pulls `root`, `command`, application-level `middleware`, and
the `services` map. An `addons` field would land alongside `middleware`
in `build_application/1`, with expansion happening before
`build_multi_services/3` returns. `validate_middleware/1` and
`validate_dependencies/1` already model the validation flow this
proposal extends — addon validation slots into the same `with` chain
(`Config.applications/1`).

**Single-service shorthand:** `build_single_service/4` returns a
single `%Service{}` for apps that declare `command` directly. The
loader needs to handle the (likely common) case of a single-service app
that also lists `addons` — the result is no longer single-service after
expansion.

**Service struct:** `source/lib/bates/service.ex` —
`%Service{name, command, port, hostname, middleware, depends_on}`. An
addon-expanded service is constructed using the same struct; no schema
change required. The framework picks the field values:

- `name` = addon name
- `command` = supplied by the addon's own definition (out of scope for
  this issue; placeholder until #20 lands)
- `hostname` = nil (addons are not user-routable)
- `port` = nil (the addon's middleware can request a port the same way
  any middleware would; see the `port` middleware pattern)
- `middleware` = `[addon_name]` plus whatever app-level middleware
  applies (see open question)
- `depends_on` = `[]`

**Middleware registry:** `source/lib/bates/middleware/registry.ex` —
maps middleware names to modules; built-ins are `asdf`, `direnv`,
`port`. Adds an unknown-name error path. Whether the addon name lookup
reuses this registry or gets its own table is an open question.

**Application GenServer:** `source/lib/bates/app.ex` consumes the
output of `Config.applications/1` unchanged. Once expansion has
happened, the runtime sees an addon as a service like any other —
`build_invocation/3`, `seed_environment/2`, the dependency graph, and
the lifecycle code all work without modification. This is the
framework's payoff.

**Tests:**

- `source/test/bates/config_test.exs` — covers single-service,
  multi-service, middleware merging, depends_on parsing, and the
  existing rejection paths. Addon parsing, expansion, edge insertion,
  and the three rejection paths belong here. The existing
  `describe "depends_on"` block is the closest model for the new
  block.
- `source/test/fixtures/*.toml` — one new fixture per shape exercised
  (short form, table form, name collision, unknown addon, duplicate
  addon, addon plus existing depends_on).

**Spec:** `specs/process-management.md` already documents Addons.
Implementation matches the spec; no spec rewrite needed.

**Outside this proposal but relevant:**

- The exports mechanism (#18, shipped) is what makes addons useful at
  runtime. The framework relies on it but does not extend it.
- Dependency ordering (#16, shipped) is the delivery vehicle for the
  implicit edge. Same.
- The `postgresql` addon (#20) is the first consumer. Framework
  decisions should leave room for that work without prescribing it.

---

## Proposed Design

### Loader: addon parsing

`build_application/1` reads `options["addons"]` after `middleware`. The
field accepts either:

- A list of strings (short form): `["postgresql"]`.
- A map of `name => table` (table form): `%{"postgresql" => %{}}`.

Both normalize to a list of addon names. (The table form's value is
ignored in v1 since no addon defines overrides — but the parser
accepts and discards it so the syntax is forward-compatible.)

A duplicate name in the short form, or a name appearing in both the
short form and table form, is rejected with a duplicate-addon error.

### Loader: addon expansion

After services have been built (single- or multi-service), the loader
expands each addon name into a `%Service{}` and appends it to the
application's service list:

```elixir
%Service{
  name: addon_name,
  command: definition.command,
  port: nil,
  hostname: nil,
  middleware: app_middleware ++ definition.middleware,
  depends_on: []
}
```

`definition` comes from `Bates.Addon.Registry.lookup!/1` —
`%{command: String.t(), middleware: [String.t()]}` with `middleware`
defaulting to `[addon_name]`. In v1 the production registry is empty;
the `postgresql` addon (#20) registers the first real entry.

### Loader: implicit edges

After the expanded list exists, for every addon (in declared order
for the short form, alphabetical for the table form):

- For every non-addon service `s` in the application: append
  `addon_name` to `s.depends_on` (preserving existing entries, no
  duplicates).
- Sibling addon services do not get the edge.

The result is a `%Service{}` list ready to flow into the existing
validation pass.

### Loader: validation

Three new error variants in `Config.applications/1`'s `with` chain,
matching the existing pattern (`{:error, {:tag, ...}}`):

- `{:error, {:unknown_addon, app_name, addon_name}}`
- `{:error, {:addon_name_collision, app_name, addon_name}}` — fires
  when the addon name matches a user-declared service.
- `{:error, {:duplicate_addon, app_name, addon_name}}` — only
  reachable through the short form (`addons = ["x", "x"]`); TOML
  itself rejects the cross-form case at parse time.

The new pipeline:

```
build services
  → expand_addons   # produces all three errors above; appends
                    # implicit edges to non-addon services
  → validate_middleware
  → validate_dependencies
```

Addon expansion happens before middleware and dependency validation
so downstream validators see a clean, fully-expanded service list with
implicit edges already in place. Cycle detection in
`validate_dependencies` therefore covers any pathological graph the
implicit edges could create.

### Addon registry

A new module — `Bates.Addon.Registry` — that maps an addon name to
its definition. Definition shape (v1):

```elixir
%{
  command: String.t(),
  middleware: [String.t()]  # defaults to [addon_name]
}
```

`middleware` is a list so future addons can compose with other
middlewares (e.g., a routable addon needing
`["port", addon_name]`). In v1 every shipped addon is expected to
default to `[addon_name]`.

The registry's API mirrors `Middleware.Registry`:

- `lookup(name) :: {:ok, definition} | {:error, :unknown}`
- `lookup!(name)` for the runtime path
- Test-gated `register/2` (the same `Mix.env() == :test` pattern
  `Middleware.Registry` uses) so framework tests can stub an addon
  without depending on #20.

The production registry holds zero entries until #20 lands. Real
`config.toml` files declaring addons get a clear `unknown_addon`
error in the meantime — that is the correct contract.

### Spec addendum

`specs/process-management.md`'s Addons section gains a short
addendum covering the four behaviors not in the spec today:

- App-level middleware applies to expanded addon services (the
  expanded service's middleware list is `app_middleware ++
  addon_definition.middleware`).
- Single-service shorthand combined with `addons = [...]` silently
  expands the application to multi-service.
- `addons = []` is a valid no-op.
- Implicit-edge ordering: short form preserves the declared TOML
  order; table form falls back to alphabetical.

---

## What This Unlocks

1. The `postgresql` addon (#20) has a place to plug in — the next
   issue is "implement the postgres-specific middleware and addon
   definition" rather than "build a framework and a postgres addon
   together."
2. A user with three services that all need Postgres can write
   `addons = ["postgresql"]` once at the application level instead of
   declaring a fourth service and adding it to three `depends_on`
   lists.
3. Future addons (Redis, Elasticsearch, MinIO) drop in by registering
   a definition; no loader changes required.

---

## Scope

In scope:

- `Bates.Addon.Registry` module with `lookup/1`, `lookup!/1`, and a
  test-gated `register/2`. Production registry holds no entries.
- `Bates.Config` parses both addon syntax forms, expands declared
  addons into services (using `app_middleware ++
  definition.middleware` for the expanded service's middleware), and
  appends implicit `depends_on` edges to non-addon services in the
  documented order.
- Three new validation variants (`unknown_addon`,
  `addon_name_collision`, `duplicate_addon`) surfaced through the
  existing loader return shape, run before `validate_middleware` and
  `validate_dependencies`.
- Single-service shorthand + addons silently expands to multi-service
  (no syntax restriction).
- Test coverage matching the issue's enumerated cases plus an empty
  `addons = []` no-op test.
- New TOML fixtures for: short form, table form, name collision,
  unknown addon, duplicate (short form), addon plus existing
  depends_on, single-service shorthand + addons, empty `addons` list.
- Spec addendum to `specs/process-management.md` covering app-level
  middleware on addons, single-service shorthand interaction, empty
  list no-op, and implicit-edge ordering.

Out of scope:

- The `postgresql` addon's command, prologue, exports, data-dir
  handling, version management. (#20)
- User-defined addon registration outside the test environment.
- Multi-instance addon support.
- Per-service opt-out from the implicit edge.
- Dashboard differentiation between addon and user services.

---

## Open Questions

None. All questions raised in refinement (2026-04-30) are resolved
and recorded in the Decided section.
