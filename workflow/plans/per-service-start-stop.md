# Plan: Per-Service Start/Stop

**Goal:** Add `bates up <app>:<service>` and `bates down <app>:<service>` (CLI + API + dashboard) with cascade-stop semantics, transitive auto-start, and a paused-state mechanism that prevents on-demand startup from undoing a user-initiated stop.

**Proposal:** [`workflow/proposals/accepted/2026-05-18-per-service-start-stop.md`](../proposals/accepted/2026-05-18-per-service-start-stop.md)

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-05-18 | Plan created from accepted proposal. 7 phases covering GenServer foundation, API, CLI, paused-loading-page, dashboard, integration tests, and spec updates. |
| 2026-05-18 | Audit complete. POCs verified directly: `:digraph_utils.reaching/2` confirmed inverse of `reachable/2`; codebase has no external controller HEEx templates so Phase 4 uses a new `PausedLive` LiveView instead of `paused.html.heex`. Phase 4 updated accordingly. |

## Why This Matters

Bates today operates at app granularity only — `bates down myapp` stops every service, including the Postgres addon. The motivating workflow is `bates down myapp:web && mix ecto.reset && bates up myapp:web` (keep Postgres up, bounce only the connection-holding service). Without a paused mechanism, the loading page would silently re-start whatever a user just stopped the next time any browser tab polls the app's hostname — making the new commands useless for their primary use case.

## Acceptance Criteria

- [ ] `bates up myapp:web` returns 0, prints `bates: started myapp:web`, and the service transitions to `up` on the dashboard.
- [ ] `bates down myapp:web` returns 0, prints `bates: stopped myapp:web`, and the service transitions to `down`.
- [ ] `bates down myapp:postgresql` (when `web`/`worker` depend on it) prints `bates: stopped myapp:postgresql (also stopped: web, worker)` and all three transition to `down`.
- [ ] `bates up myapp:worker` (when `postgresql`/`web` are down deps) auto-starts the chain and all reach `up`.
- [ ] After `bates down myapp:web`, hitting `https://myapp.test` in a browser shows the paused view with a Resume button; clicking Resume completes the normal block-and-redirect flow and lands on the app.
- [ ] After `bates down myapp`, a non-browser `curl -H 'Accept: application/json' https://myapp.test/...` returns 503 with `{"app": ..., "status": "paused", ...}` (and does NOT auto-restart the app).
- [ ] `bates up myapp` clears paused; subsequent browser hits proceed normally.
- [ ] Single-service apps: dashboard shows one row with app-level buttons only (no per-service buttons). `bates down myapp:myapp` works equivalently to `bates down myapp`.
- [ ] Multi-service apps: each service row has Start/Stop buttons reflecting the service's current state.
- [ ] `bates restart myapp:web` is rejected with the usage error (per-service `restart` not supported).
- [ ] `mix test` passes end-to-end with no skipped suites.
- [ ] `specs/control-interface.md`, `specs/cli.md`, and `specs/process-management.md` are updated per the proposal's spec-updates list.

## Phase 1 — `App` GenServer: paused flag, per-service entrypoints, closures

**Files:**
- `source/lib/bates/app.ex` — primary surface
- `source/test/bates/app_test.exs` — coverage

**Changes:**

1. Add `paused: false` to the GenServer state map in `init/1` (line 80–88).
2. Add public functions:
   - `App.up(name, service_name)` — calls `GenServer.call(via_tuple(name), {:up, service_name}, @timeout)`.
   - `App.down(name, service_name)` — calls `GenServer.call(via_tuple(name), {:down, service_name}, @timeout)`. Returns `{:ok, cascaded}` where `cascaded` is a list of `%{service: name, status: "down"}` maps for every dependent that was stopped.
   - `App.paused?(name)` — calls `GenServer.call(via_tuple(name), :paused?)`. (Or fold into `App.snapshot/1`; pick whichever reads cleaner — a separate `:paused?` call is simpler for the loading controller.)
3. New `handle_call` clauses:
   - `handle_call(:up, _, state)` — set `paused: false`, then existing start logic. (Update existing clause, line 91–94.)
   - `handle_call(:down, _, state)` — set `paused: true`, then existing stop logic. (Update existing clause, line 101–118.)
   - `handle_call({:up, service_name}, _, state)` — clear paused; build forward closure (transitive `depends_on` of `service_name` plus the target), restrict `start_eligible/1`'s iteration to that set, run the fixpoint walk. Reuse `start_service/3` and `eligible_to_start?/2`.
   - `handle_call({:down, service_name}, _, state)` — set paused; build dependents closure (every service that transitively `depends_on` the target plus the target); walk reverse-topo over that closure stopping each service with `pid != nil` via `stop_service/3`. Collect the cascaded list (excluding the target itself) and return as second tuple element.
   - `handle_call(:paused?, _, state)` — return `{:reply, state.paused, state}`.
4. New helpers (private):
   - `forward_closure/2` — given a service name and the services map, walks `depends_on` edges forward to produce the set of services in the dep closure (including target).
   - `dependents_closure/2` — inverse of the above: services whose transitive `depends_on` includes the target.
   - Reuse `build_dependency_graph/1` and `:digraph_utils.reachable/2` (forward) / `:digraph_utils.reaching/2` (reverse) for both. `reverse_topological_order/1` is already there; extend it (or write a sibling) that takes a service-name subset.
5. Broadcast hygiene: every state change still calls `broadcast_app/2` and `broadcast_service/3` per the existing pattern — no new topic, just naturally extended coverage.

**Test additions (`app_test.exs`):**
- `App.down(name, "postgresql")` with `web`/`worker` depending on it → all three down, returned `cascaded` lists `web` and `worker` in reverse-topo order.
- `App.down(name, "worker")` (a leaf in the dep graph) → only worker stops; `cascaded` is empty.
- `App.up(name, "worker")` when all deps are down → `vite`/`web`/`worker` all reach `up`; `web` only enters `starting` after `vite` is `up`.
- `App.down/2` sets paused; `App.up/2` and `App.up/1` clear it.
- `App.down/1` (existing) now also sets paused (previously did not).
- Empty cascade: `App.down(name, "postgresql")` when web/worker are already down → cascade list is empty; paused still set.

**Why grouped:** The GenServer surface is the foundation; nothing else can move until these calls and the paused flag exist. No external surface change yet — purely internal API.

## Phase 2 — API: routes and `ProcessController` actions

**Files:**
- `source/lib/bates_web/router.ex`
- `source/lib/bates_web/controllers/process_controller.ex`
- `source/test/bates_web/controllers/process_controller_test.exs`

**Changes:**

1. `router.ex`: add two routes under the API scope (after the existing `:restart` line):
   ```elixir
   post "/processes/:app/services/:service/start", ProcessController, :start_service
   post "/processes/:app/services/:service/stop",  ProcessController, :stop_service
   ```
2. `process_controller.ex`:
   - **`start_service/2`** — `%{"app" => app, "service" => service}`. Verify the app exists (`ProcessSupervisor.app_pid/1`); 404 if not. Verify the service exists in `App.services(app)`; 404 if not. Subscribe to `"service:#{app}:#{service}"`. Call `App.up(app, service)` (catching `:exit`). Block on a receive loop similar to `receive_settled/3` but waiting for `{:status, "up"}` or `{:status, "crashed", _}` on the service topic, with a 60s budget. Respond with the status-only shape: `{app, service, status, port, hostname}`. On crash → 422, on timeout → 504.
   - **`stop_service/2`** — `%{"app" => app, "service" => service}`. Same 404 checks. Call `App.down(app, service)`. Return `{app, service, status: "down", cascaded: [...]}` (`cascaded` from `App.down/2`'s return value). On error → 422.
   - Reuse `receive_settled/3`'s structure as much as possible — extract the deadline/receive helpers if they're useful for both contexts; otherwise duplicate the loop (it's small).
3. `process_controller_test.exs`:
   - Per-service start success: app + service exist → 200 with expected payload.
   - Per-service stop success with cascaded list shape (use `multi_service_with_deps_config.toml`).
   - 404 cases: unknown app, unknown service.
   - 422 case: service crashes during start (simulate via a config with a `false` command or similar).
   - 504 case: readiness timeout (will need the existing `@readiness_timeout` override pattern).
   - Stop with empty cascade: `cascaded: []`.

**Why grouped:** API is the second layer. CLI and dashboard both depend on it; landing it here unblocks parallel work in phases 3 and 4–5.

## Phase 3 — CLI: parse `<app>:<service>` and render cascade line

**Files:**
- `source/lib/bates/cli.ex`
- `source/lib/bates/cli/up.ex`
- `source/lib/bates/cli/down.ex`
- `source/lib/bates/cli/restart.ex` (small change: reject `<app>:<service>` form)
- `source/test/bates/cli_test.exs`
- `source/test/bates/cli/up_test.exs`
- `source/test/bates/cli/down_test.exs`
- `source/test/bates/cli/restart_test.exs`

**Changes:**

1. `Bates.CLI.Up.run/1`: split on `:`.
   - No `:` → existing app-level `POST /processes/<name>/start`.
   - One `:` → `POST /processes/<app>/services/<service>/start`; success line is `bates: started <app>:<service>`.
   - Two-or-more `:` or empty either side → usage error to stderr, return 2.
2. `Bates.CLI.Down.run/1`: same split logic. Per-service path → `POST /processes/<app>/services/<service>/stop`. Success line reads `body["cascaded"]`; if non-empty, append ` (also stopped: <name1>, <name2>)` (just service names, comma-separated). Cascaded order is what the API returned (reverse-topo, matches the order services were actually stopped).
3. `Bates.CLI.Restart.run/1`: if name contains `:`, write `bates restart does not support per-service form; use 'bates down <app>:<service>' followed by 'bates up <app>:<service>'` to stderr, return 2. Otherwise unchanged.
4. `Bates.CLI.dispatch/1`: no change to the dispatcher itself — name parsing stays inside each subcommand (matches the proposal). The `usage/0` text doesn't need a per-service variant explicitly; the `<name>` shorthand covers both forms.
5. Tests:
   - `up_test.exs`: per-service success path, per-service 404, per-service 422, validation errors for empty/multi-colon forms.
   - `down_test.exs`: per-service success path, cascade rendering with non-empty `cascaded`, empty-cascade rendering, validation errors.
   - `restart_test.exs`: per-service form rejected with usage error.

**Why grouped:** All three CLI modules share the same parsing concern. Phase 2 must be in place because all three need real API endpoints; this phase has no other dependencies.

## Phase 4 — Loading flow: paused mode

**Files:**
- `source/lib/bates_web/controllers/loading_controller.ex`
- `source/lib/bates_web/live/paused_live.ex` (new)
- `source/test/bates_web/controllers/loading_controller_test.exs`
- `source/test/bates_web/live/paused_live_test.exs` (new, if desired)

**Changes:**

1. `loading_controller.ex` — `show/2` checks `App.paused?(app_name)` near the top. Three branches:
   - **Paused AND resume requested** (`conn.params["resume"] == "true"`): fall through to the existing flow. The downstream `App.up/1` call (triggered by `LoadingLive` dead-render or `show_blocking/3`) clears the flag per Phase 1.
   - **Paused AND browser** (Accept includes `text/html`): `live_render(conn, BatesWeb.PausedLive, session: %{"app_name" => app_name, "service_name" => service_name})`.
   - **Paused AND non-browser**: `conn |> put_status(:service_unavailable) |> json(%{app: app_name, status: "paused", reason: "Application is paused. Visit https://bates.test to resume, or run 'bates up #{app_name}'."})`.
2. `loading_live.ex` — no changes needed. The controller short-circuits before reaching `live_render(conn, BatesWeb.LoadingLive, ...)` when paused.
3. New `BatesWeb.PausedLive`:
   - Pattern matches `BatesWeb.LoadingLive` (line 14 onwards): `use BatesWeb, :live_view`, `mount/3` takes session params, no PubSub subscription needed (paused page is static — no live updates), render inline `~H""" """`.
   - Mount: fetch the service list (`App.services(app_name)`), assign `app_name`, `service_name`, `services`. Don't call `safe_up/1` — that's the whole point.
   - Render: Bates wordmark header, "<app> is paused" title, service list with status lamps (copy the small `lamp_state/1` helpers from `loading_live.ex:189-193` rather than coupling the modules), single `<a href={current_url <> "?resume=true"}>Resume</a>` styled as a button (reuse `bates-btn` classes from the dashboard).
   - No `handle_info` clauses — page is static.
4. `router.ex` — no change. The resume mechanism is GET-with-query-param on the same `/loading/:app_name/:service_name` route, so the existing route covers it.
5. Tests in `loading_controller_test.exs`:
   - Paused + browser → 200 HTML with "paused" in title, service names, Resume link with `?resume=true`.
   - Paused + JSON → 503 with `{"app": ..., "status": "paused", "reason": ...}` matching the expected shape.
   - Paused + `?resume=true` → falls through to normal flow (mounts `LoadingLive`); assert via the resulting `App.paused?` state being cleared after the request.
   - Non-paused flow unchanged — existing tests still pass without modification.

**Why grouped:** The paused page is one self-contained vertical: controller branch + LiveView + tests. Independent of CLI work, can land in parallel with Phase 3 once Phase 1 is in.

**Pattern reference:** `BatesWeb.LoadingLive` (`source/lib/bates_web/live/loading_live.ex`) is the model — same `use BatesWeb, :live_view`, same `live_render/3` invocation in the controller, same inline `~H` render. Phase 4 mirrors that structure; the only meaningful difference is no PubSub subscriptions and no startup trigger.

## Phase 5 — Dashboard: per-service buttons

**Files:**
- `source/lib/bates_web/live/dashboard_live.ex`
- `source/test/bates_web/live/dashboard_live_test.exs`

**Changes:**

1. Add two new `handle_event` clauses (next to the existing `start`/`stop`/`restart` at lines 36–52):
   ```elixir
   def handle_event("start_service", %{"app" => app, "service" => service}, socket) do
     App.up(app, service)
     {:noreply, socket}
   end

   def handle_event("stop_service", %{"app" => app, "service" => service}, socket) do
     App.down(app, service)
     {:noreply, socket}
   end
   ```
2. Update `service_row/1` (line 244–276): in multi-service apps, append a controls cell with Start and Stop buttons.
   - Need to thread the parent app name into the component (either pass it down via the assigns or restructure the call site). Simplest: add `attr :app_name, :string, required: true` and pass it from the parent `<.service_row :for={svc <- @app.services} svc={svc} app_name={@app.name} multi_service={@app.multi_service} />`. Skip the controls cell when `multi_service` is false.
   - Button visibility: Start disabled when `svc.status in ["up", "starting"]`; Stop disabled when `svc.status == "down"`.
3. Add a `<div class="bates-services__cell">Actions</div>` to the services head (line 232) when the app is multi-service. (Or always show the column and leave it empty for single-service rows — simpler to keep both layouts; pick whichever renders cleaner. Lean: column visible only on multi-service.)
4. CSS: the existing dashboard.css (or however the styles are organized) probably needs a new class for the per-service button group. Keep changes minimal — reuse `bates-btn bates-btn--ghost` and `bates-btn--ghost-destructive` already used by app-level controls.
5. Tests in `dashboard_live_test.exs`:
   - Multi-service app: per-service buttons render for each row.
   - Single-service app: no per-service buttons render.
   - `start_service` event triggers `App.up/2` with the right args. (Use a test that asserts on resulting state via the GenServer rather than mocking.)
   - `stop_service` event triggers cascade behavior live (status broadcasts arrive and dashboard re-renders).
   - Button disabled states match service status.

**Why grouped:** Dashboard work is self-contained. Depends on Phase 1 (the `App.up/2` / `App.down/2` calls) but is otherwise parallel to phases 3 and 4.

## Phase 6 — Test fixture extension and full-graph cases

**Files:**
- `source/test/fixtures/multi_service_with_deps_config.toml`
- (cross-cutting test additions to `app_test.exs`, `process_controller_test.exs`)

**Changes:**

The fixture already has `worker → web → vite`. That's a clean 3-deep chain for the cascade and auto-start scenarios. No fixture file change is strictly needed unless additional shapes are desired. If a wider fan-out is useful (e.g., two services depending on the same root, exercising the cascade collecting multiple parallel dependents), add a fourth service to the fixture:

```toml
[myapp.services.scheduler]
command = "bin/scheduler"
depends_on = ["vite"]
```

Then `bates down myapp:vite` cascade-stops `web`, `worker`, AND `scheduler` (fan-out test). This is the only meaningful extension; otherwise the existing fixture suffices.

Cross-cutting tests to add (in the existing files, not new files):
- Full pipeline: CLI → API → GenServer for both per-service start and stop.
- Paused interaction: API call from CLI sets paused; HTTP hit on the app's hostname renders paused page.
- Resume interaction: paused page resume clears paused; subsequent CLI calls succeed normally.

**Why grouped:** This is the integration phase — make sure the pieces work end-to-end before declaring done.

## Phase 7 — Spec updates

**Files:**
- `specs/control-interface.md`
- `specs/cli.md`
- `specs/process-management.md`

**Changes:**

1. `specs/control-interface.md`:
   - Rewrite the "Controls" section under Dashboard (lines 34–45): document app-level and per-service controls; explicitly remove the "Controls are application-level only — there are no per-service controls" line.
   - Extend "Loading Page" (lines 47–78) with a "Paused Apps" subsection: when an app is paused, the loading page renders a static paused view with a Resume button instead of running the blocking start flow. Non-HTML clients get 503 JSON.
   - Extend "API" (line 80 onwards) with:
     - New endpoints `POST .../services/:service/start` and `POST .../services/:service/stop`.
     - Response shapes: status-only for start, with-cascaded-array for stop.
     - Note that the existing `POST /processes/:name/stop` now also sets the app to paused (this is the breaking-behavior call-out from Q5).
2. `specs/cli.md`:
   - Extend `bates up <name>` and `bates down <name>` (lines 48–57) to document the `<app>:<service>` form, including the cascade-output line for `down`.
   - Note that `bates restart` does not have a per-service form.
   - Note (in the same section or under Server Communication) that any user-initiated stop pauses the app and the paused page intercepts on-demand startup until a user-initiated `up`.
3. `specs/process-management.md`:
   - Add a "Per-Service Lifecycle Operations" subsection covering:
     - Cascade-stop semantics (reverse-topo over dependents).
     - Transitive auto-start (forward over dependencies).
     - The `paused` flag at app level — what sets it, what clears it, what reads it.
   - Update the stale-export note (lines 284–290) with a sentence pointing out that the no-per-service-restart decision structurally avoids the easy-to-hit stale-export window.
   - Single-service apps: `<app>:<service>` works uniformly via the grammar (one-line note).

**Why grouped:** Spec updates are the documentation finale — done after the implementation lands so the descriptions match reality.

## What Does NOT Change

- App-level `bates up`/`bates down`/`bates restart` semantics (other than app-level `down` now also setting paused).
- Existing API routes `POST /processes/:name/start|stop|restart`.
- The `bates env <app>` exports surface (no per-service env command).
- The `bates status` output format (already shows per-service rows).
- Dependency declaration syntax (`depends_on` field).
- Caddy route management — `revert_caddy_route`/`update_route` calls fire per-service exactly as today.
- Persistence — paused is in-memory, no disk state.

## Where to Start

> These are pointers from the codebase survey at plan creation time. Files may have changed by execution time. Verify before acting.

**Core flow to trace (what calls what):**
- `Bates.CLI.Down.run/1` → `Bates.CLI.Client.post/2` → HTTPS → `BatesWeb.Router` → `BatesWeb.ProcessController.stop/2` → `Bates.App.down/1` → `stop_service/3` → `Bates.Caddy.revert_route/1` + PubSub broadcast.
- For the new per-service path, add a parallel pipe: `Down.run/1` (with `:` parsing) → `Client.post/2` (new URL) → `Router` (new route) → `ProcessController.stop_service/2` → `App.down/2` (new) → walk + `stop_service/3` per cascaded service.

**Paused-page integration points:**
- `source/lib/bates_web/controllers/loading_controller.ex:8` — entry point. The paused check goes near the top of `show/2`.
- `source/lib/bates_web/live/loading_live.ex:21` — the dead-render `safe_up/1` is what triggers app start. Don't reach this code path when paused.
- The current non-browser response in `show_blocking/3` uses `text(...)`; for the paused JSON 503, use `json(...)` like the API controllers do.

**Existing tests to mirror:**
- `source/test/bates/app_test.exs` — patterns for testing GenServer transitions, dep graph behavior. New per-service tests slot in alongside the existing app-level lifecycle tests.
- `source/test/bates_web/controllers/process_controller_test.exs` — patterns for testing 404/422/504, JSON shapes, blocking semantics.
- `source/test/bates/cli/down_test.exs` and `up_test.exs` — patterns for CLI tests using captured IO and a fixture endpoint.
- `source/test/bates_web/controllers/loading_controller_test.exs` — current loading-page coverage, including the browser-vs-blocking split.
- `source/test/bates_web/live/dashboard_live_test.exs` — LiveView test patterns for events and rendered output.

**Fixtures:**
- `source/test/fixtures/multi_service_with_deps_config.toml` — has the `worker → web → vite` chain. Use this for cascade and auto-start tests. Optionally extend with a `scheduler` service for fan-out coverage.
- `source/test/fixtures/multi_service_config.toml` — no deps. Use for independent-services cases (per-service stop with no cascade).

**Helper functions worth knowing about:**
- `Bates.App.build_dependency_graph/1` and `Bates.App.reverse_topological_order/1` — already exist. Reuse rather than rewrite.
- `:digraph_utils.reachable/2` — forward closure. `:digraph_utils.reaching/2` — reverse closure. Both useful for the new helpers.
- `Bates.App.start_eligible/1` — already does the fixpoint walk for per-service start, just over all services. Restrict to a subset by filtering its inner reduce.
- `Bates.App.stop_service/3` — already handles a single service's stop including Caddy revert + broadcast. Cascade is just calling it per service in reverse-topo order.

**Routing reminder:**
- Stopping a service that has a `hostname` reverts its Caddy route (`stop_service/3` calls `revert_caddy_route/1`). After Phase 1 lands, this happens per cascaded service automatically — no new wiring.
- Starting a service assigns a port and updates the route (`start_service/3` calls `update_caddy_route/2`). Same — no new wiring.

---

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-05-18 | READY FOR AUTONOMOUS EXECUTION | All three POC gaps verified directly (digraph_utils inverse semantics confirmed; codebase uses inline LiveView pattern, not external HEEx templates → Phase 4 updated to use new `PausedLive`; crashing-service fixture not needed — inline test setup suffices). No blockers. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

All technical assumptions verified. Phase 4's template approach was the only design ambiguity and is now resolved (use `PausedLive` LiveView, matching `LoadingLive`).

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| `source/test/fixtures/multi_service_with_deps_config.toml` | Ready | Exists with `worker → web → vite` chain as expected. |
| `source/test/fixtures/multi_service_config.toml` | Ready | Exists (no-deps fixture, useful for empty-cascade cases). |
| Crashing-service fixture | Not needed | Tests inline service definitions via `start_supervised!({App, {name, root, [svc]}})`; a service with `command = "/bin/false"` triggers `:crashed` via `extract_exit_status/1`. No new fixture file required. |
| Erlang OTP 27 | Ready | `.tool-versions` pins `erlang 27.3.4.10`. `:digraph_utils.reaching/2` confirmed available. |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `:digraph_utils.reachable/2` | Ready | Already used in `app.ex:540`. |
| `:digraph_utils.reaching/2` | Ready (verified) | POC confirmed inverse semantics: graph `a→b, c→b`; `reaching([b]) = [a, c, b]`. |
| Phoenix 1.7 + LiveView 1.0 | Ready | `mix.exs` declares `~> 1.7` and `~> 1.0`. |
| Jason | Ready | Already used by `CLI.Client` and `ProcessController`. |
| `BatesWeb.ConnCase` + `start_supervised!` | Ready | Established pattern in existing tests. |

### Open Questions

| # | Question | Blocking? | Notes |
|---|----------|-----------|-------|
| 1 | `:digraph_utils.reaching/2` semantics | No | **Resolved.** Verified inverse of `reachable/2`. |
| 2 | LoadingController template location | No | **Resolved.** Codebase has no external controller HEEx templates; use new `PausedLive` (inline `~H`) matching `LoadingLive`. Phase 4 updated. |
| 3 | Crashing-service fixture pattern | No | **Resolved.** Inline service in test setup with `command = "/bin/false"`; no new fixture file needed. |
| 4 | Does paused state warrant a mention in `specs/system-overview.md` or `specs/routing.md`? | No | **Resolved (no change).** `system-overview.md` operates at app-level summary; pointing to `process-management.md` is sufficient. `routing.md` describes Caddy routes, which behave identically regardless of paused state (the control interface decides what to render). |

### POC Gaps

| # | Assumption | Experiment | Why It Matters | Effort |
|---|-----------|------------|----------------|--------|
| 1 | `:digraph_utils.reaching/2` is inverse of `reachable/2` | Built test graph `a→b, c→b`; `reachable([a]) = [b, a]`, `reaching([b]) = [a, c, b]`. ✅ Confirmed. | Cascade-stop's `dependents_closure/2` relies on this. | Resolved (quick) |
| 2 | LoadingController uses external HEEx templates | Grepped `source/lib/bates_web/`. No `_HTML` view modules for controllers; only LiveView inline `~H` and `error_html.ex`/`error_json.ex` simple fallbacks. ✅ Confirmed pattern. | Phase 4 file layout. | Resolved (quick) |
| 3 | `command = "/bin/false"` triggers `:crashed` | Read `extract_exit_status/1` (app.ex:660); non-`:normal` exit reasons map to `:crashed`. ✅ Confirmed by code review. | Test for 422 crash path. | Resolved (quick) |

### Pre-Work

None. All gaps resolved during audit.

### Blockers

None identified.

### Spec Update Coverage

The plan's Phase 7 explicitly updates the three specs that need changes:
- `specs/control-interface.md` — Controls section, Loading Page (Paused subsection), API endpoints, app-level stop behavior note.
- `specs/cli.md` — `bates up`/`bates down` `<app>:<service>` form, cascade output line, paused-state interaction.
- `specs/process-management.md` — Per-Service Lifecycle Operations subsection (cascade, auto-start, paused flag), stale-export note update.

Considered and intentionally **not** updated: `specs/system-overview.md` (high-level summary unchanged), `specs/routing.md` (Caddy behavior unchanged), `specs/sandbox/*` (not part of authoritative specs per CDD).
