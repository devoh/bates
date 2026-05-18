# Per-Service Start/Stop — Proposal

**Status:** Accepted
**Date:** 2026-05-18
**Author:** Tyler + Claude
**Refined:** 2026-05-18 (14 questions resolved; per-service `restart` dropped; paused state added)
**Accepted:** 2026-05-18

## Summary

Add the ability to start and stop an individual service within an
application without acting on the whole app. Surface this through both
the CLI (`bates up myapp:web`, `bates down myapp:web`) and the dashboard
(per-service buttons next to each service row on multi-service apps).
The motivating workflow is stopping a single web/worker service to
release database connections before `mix ecto.reset` (or similar),
without bouncing the local Postgres addon and losing any in-flight state
the developer would rather keep.

Stopping a service cascades to its dependents; starting a service
auto-starts its dependencies. There is no per-service `restart` — users
compose `down` + `up`, which avoids the stale-export window that a
producer restart would create.

Any user-initiated stop also marks the app as `paused`. The loading
page renders a paused view (with a Resume button) instead of
auto-restarting the app when a browser hits its hostname; without this,
a polling browser would silently revive whatever the user just stopped.

This reverses a decision explicitly documented in
`specs/control-interface.md:44` ("Controls are application-level only —
there are no per-service controls").

---

## Problem

Bates today is application-coarse: `bates up myapp` brings all services
in `myapp` up, and `bates down myapp` brings them all down. For a single
service running standalone, that's correct. For a multi-service
application — Rails + Sidekiq + Vite + Postgres-as-addon — it's the
wrong granularity in several real workflows:

- **Resetting the database while keeping the DB process up.** `mix
  ecto.reset` (or equivalent) requires the application's connection pool
  to release its handles. The only existing levers are `bates down
  myapp` (which also stops Postgres, defeating the purpose) or killing
  the OS process by hand (which races with Bates's supervisor and won't
  update the dashboard cleanly).
- **Restarting a worker without bouncing the web server.** A Sidekiq
  process gone wedged shouldn't require restarting the Rails server (and
  invalidating its dev cache, asset compile, etc.).
- **Restarting Vite without restarting Rails.** Same pattern in reverse.
- **Recovering a crashed service after fixing the cause.** Today the
  recovery path is to call `:up` on the whole application; per-service
  `up` is more surgical and more honest about intent.

The application-only granularity made sense at the time the multi-
service support landed (#4): the implementation was simpler, the spec
called it out as deliberate, and there were no addons yet to dramatize
the "stop one but not the other" use case. The addons framework (#19)
changed the calculus — implicitly-depended-on services make
"stop-everything" much more disruptive than it was when every service
was peer-level.

---

## Decided

### Surface area

- **Per-service controls coexist with app-level controls.** Existing
  `bates up <app>` / `bates down <app>` / `bates restart <app>`
  semantics are unchanged. The new commands are additive.
- **Per-service surface is `start` and `stop` only — no `restart`.** A
  per-service restart of a producer (e.g., postgres) would either leave
  dependents with stale exports (broken) or cascade-restart them
  (defeats the point — `bates restart <app>` already does that). The
  user composes `bates down <app>:<service>` followed by
  `bates up <app>:<service>` instead. The cascade-stop in step 1 puts
  dependents in `down`, the start in step 2 only starts the target,
  and the user explicitly brings dependents back when they want a
  fresh env. No stale-state path exists. (Q3, Q4)
- **Identifier syntax is `<app>:<service>`.** Matches the log prefix
  convention (`[myapp:web]`) already used in `Bates.App.log/3`. Plain
  `bates up myapp` continues to mean "the whole app." For
  single-service apps (shorthand or otherwise), the grammar applies
  uniformly: `bates down myapp:myapp` is valid and equivalent to
  `bates down myapp`. Agents and scripts don't have to discover an
  app's service shape before constructing the command. (Q6)
- **The API is JSON.** Per-service endpoints return per-service status
  payloads; no plain-text or empty bodies.
- **Single-service apps don't get a second dashboard control surface.**
  For an app with exactly one service, the dashboard renders one row
  with one control set (the app-level one). Per-service buttons appear
  only on multi-service apps. CLI grammar is uniform per the previous
  bullet; this only affects the UI.

### Lifecycle

- **Stop cascades.** `bates down <app>:<service>` walks the reverse
  topological order, stopping every service in the closure of the
  target plus its transitive dependents (filtered to services with
  `pid != nil`). Mirrors `App.down/1`'s existing reverse-topo walk,
  scoped to the dependents-closure. (Q1)
- **Start auto-starts dependencies.** `bates up <app>:<service>`
  transitively starts every service in the target's `depends_on`
  closure that is currently `down`, in dependency order, then starts
  the target. Mirrors `App.up/1`'s graph walk via `start_eligible/1`.
  (Q2)
- **Empty cascades are no-ops by construction.** When the target has
  no live dependents (stop) or no down dependencies (start), the
  cascade walk is naturally empty. No special case needed. (Q14)

### Paused state and on-demand startup

- **A user-initiated stop pauses the app.** Any explicit `down` —
  app-level (`bates down myapp`) or per-service (`bates down
  myapp:postgresql`) — sets a `paused` flag on the application's
  `App` GenServer. The flag is in-memory, no persistence; `batesd`
  restart clears it (acceptable: no apps are running after a daemon
  restart anyway).
- **The loading page respects paused.** When a `.test` hostname is
  hit for a paused app, the loading controller renders a paused
  variant of its template (app name, snapshot of service statuses, a
  single Resume button) instead of calling `App.up/1`. This is the
  same controller, the same route — only the rendered HTML differs.
  Non-HTML clients (`Accept: application/json`) get 503 with a JSON
  body explaining the paused state.
- **Resume re-enters the normal loading flow.** Clicking Resume POSTs
  to the loading URL with a resume parameter; the controller clears
  the paused flag, falls through to the normal `App.up/1` + block +
  redirect flow, and the user lands on the requested service's
  hostname once it's `up`.
- **Any user-initiated start clears paused.** App-level
  (`bates up myapp`) or per-service (`bates up myapp:web`) start
  clears the flag before proceeding. The dashboard's Start buttons
  do the same via `App.up/1` (which is the single funnel through
  which the flag is cleared).
- **This changes existing behavior for app-level stop.** Today,
  `bates down myapp` leaves the app in a state where any browser hit
  re-starts it via the loading page. After this change, an
  app-level stop also pauses. This is intentional: a user who said
  `down` meant `down`. Worth flagging in `specs/control-interface.md`
  and CLI help. (Q5)

### API

- **Endpoints.** Nested under `/processes/<app>/services/<service>/`:
  - `POST /processes/<app>/services/<service>/start`
  - `POST /processes/<app>/services/<service>/stop`
  (No `restart` endpoint per the surface-area decision above.)
- **Start blocks until the target is `up`.** Subscribes to
  `"service:<app>:<service>"` PubSub and waits for `{:status, "up"}`
  or `{:status, "crashed", ...}`, with a 60-second readiness budget
  per service (same as the app-level endpoint's per-service window).
  Auto-started dependencies do not share this budget — each carries
  its own. Implementation reuses `receive_settled/3`'s shape from
  `process_controller.ex:130`. (Q8)
- **Response payload — start.** Status-only, no exports:
  ```json
  {"app": "myapp", "service": "web", "status": "up",
   "port": 52341, "hostname": "myapp.test"}
  ```
  `bates env <app>` remains the dedicated surface for exports;
  duplicating them in every per-service response is dead weight. (Q9)
- **Response payload — stop.** Includes a `cascaded` array listing
  every dependent that also stopped:
  ```json
  {"app": "myapp", "service": "postgresql", "status": "down",
   "cascaded": [{"service": "web", "status": "down"},
                {"service": "worker", "status": "down"}]}
  ```
  Empty array when nothing cascaded. Lets the CLI render the
  `(also stopped: …)` line without a second round-trip. The
  dashboard gets this via PubSub broadcasts and doesn't need the
  field. (Q10)

### CLI

- **Success output for stop.** Single line:
  - No cascade: `bates: stopped myapp:postgresql`
  - With cascade: `bates: stopped myapp:postgresql (also stopped: web, worker)`
  Script-friendly (one line per command), surfaces the side effect,
  parenthetical only when non-empty. (Q11)
- **Success output for start.** Single line: `bates: started
  myapp:web`. (Auto-started dependencies are not enumerated — they
  go in the dashboard.)

### Dashboard

- **No confirmation modal for cascade-stop.** Live PubSub status
  reflects the cascade as it happens; the dashboard surface stays
  free of modal UX. CLI users get the `(also stopped: …)` line; UI
  users see the rows transition in real time. (Q7)
- **New LiveView events: `start_service` and `stop_service`.** Each
  carries both `app` and `service` in the payload. Flat
  `handle_event` clauses next to the existing `start`/`stop`/`restart`
  app-level handlers. No `restart_service` event (per surface-area
  decision). (Q12)
- **Per-service buttons** sit on each service row in multi-service
  apps. Start and Stop only. Visibility mirrors app-level buttons:
  Stop disabled when status is `down`, Start disabled when status is
  `up` or `starting`.

### Tests

- **Extend `test/fixtures/multi_service_config.toml`.** Add the
  scenarios needed for per-service start/stop alongside the existing
  dependency-ordering scenarios. Same fixture, broader coverage. No
  new fixture file. (Q13)

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted
> or executed. These are pointers to help orient, not implementation
> instructions.

**The current spec position to reverse:**

- `specs/control-interface.md:34-45` — Controls section explicitly
  states "Controls are application-level only — there are no per-service
  controls." This line needs to change as part of this work; the
  surrounding description of which buttons show under which state also
  needs to grow a per-service variant.
- `specs/cli.md:48-60` — `bates up <name>` / `bates down <name>` /
  `bates restart <name>` documentation needs to extend to the
  `<app>:<service>` form.

**Where per-service control already half-exists in the code:**

- `source/lib/bates/app.ex:307-391` — `start_eligible/1` and
  `start_service/3` already start one service at a time inside the
  app-level `:up` flow. They are gated only on dependency readiness.
  Per-service `:up` is mostly a question of exposing this as a public
  API and skipping the "iterate over all services" outer loop.
- `source/lib/bates/app.ex:393-425` — `stop_service/3` similarly
  operates on a single service and already handles the Caddy revert and
  PubSub broadcast. Per-service `:down` is mostly about exposing it.
- `source/lib/bates/app.ex:46-48` — `service_status/2` already provides
  a single-service status query through the GenServer interface, which
  the per-service start/stop responses can reuse.
- `source/lib/bates/app.ex:281-289` — `reverse_topological_order/1` and
  `build_dependency_graph/1` give us the graph machinery already needed
  for cascade-stop semantics, if we choose them.

**Control interface plumbing to extend:**

- `source/lib/bates_web/router.ex:17-21` — current routes are flat:
  `POST /processes/:name/start|stop|restart`. New routes need to nest:
  `POST /processes/:app/services/:service/start|stop|restart`.
- `source/lib/bates_web/controllers/process_controller.ex` — every
  action takes `%{"name" => name}`. New actions take both an app and a
  service name and call into the new App API surface.
- `source/lib/bates_web/live/dashboard_live.ex` (not yet read in
  detail) is where the new per-service buttons live in the UI.

**CLI plumbing to extend:**

- `source/lib/bates/cli.ex` — dispatcher needs to recognize
  `<app>:<service>` and route to per-service handlers. The cleanest
  shape is probably an argv-parse step inside each of
  `Bates.CLI.Up.run/1`, `Bates.CLI.Down.run/1`, `Bates.CLI.Restart.run/1`
  that splits on `:` and chooses the per-service endpoint.
- `source/lib/bates/cli/{up,down,restart}.ex` — each currently calls a
  single HTTP endpoint. Per-service variants are a different URL but
  otherwise the same shape.
- `source/lib/bates/cli/client.ex` — already abstracts the HTTP
  request; no change beyond a new URL helper.

**Loading-page interaction worth noting:**

- `source/lib/bates_web/controllers/loading_controller.ex` (and
  `specs/control-interface.md:48-77`) — when a request hits a
  `.test` hostname for a down app, the loading page calls `App.up/1`
  on the whole application. If a user has manually stopped
  `myapp:postgresql`, the next browser hit to `myapp.test` will
  silently re-start it. This is consistent with the on-demand-startup
  invariant but might surprise the user. See Open Questions.

**Stale exports today:**

- `specs/process-management.md:284-290` already documents the
  stale-export window: a consumer holding an old `PGPORT` keeps it
  until the consumer itself is restarted. Per-service restart of a
  producer makes this window much easier to hit (today it requires a
  full app down/up cycle to even risk it, except via implicit
  scheduling). See Open Questions.

---

## Proposed Design

### Identifier syntax: `<app>:<service>`

Reuses the existing log-prefix convention. The dispatcher treats `:`
inside a control-command argument as the app/service separator. `bates
up myapp` continues to operate on the whole app; `bates up myapp:web`
operates on just `web` within `myapp`.

Rejected alternatives:

- `myapp/web` — would conflict with any future intent to support paths
  or namespaces, and reads ambiguously next to URLs.
- `myapp.web` — collides with the `.test` TLD scheme visually.
- A separate `--service` flag (`bates up myapp --service web`) —
  verbose, and the `:` form is short enough that a flag is unjustified.

### API: nested under `/processes/<app>/services/<service>/`

Two endpoints; response shapes per the Decided section above.

```
POST   /processes/<app>/services/<service>/start  → 200 status-only
POST   /processes/<app>/services/<service>/stop   → 200 status + cascaded[]
```

Error responses follow the existing convention:

```
→ 404 unknown app or unknown service
→ 422 service crashed
→ 504 readiness timeout (start only)
```

The existing `/processes/<app>/start|stop|restart` endpoints remain
unchanged and remain the right call when the user means "the whole
app."

### CLI

`bates up myapp:web` → `POST /processes/myapp/services/web/start`.
Print `bates: started myapp:web` on success.

`bates down myapp:web` → `POST /processes/myapp/services/web/stop`.
Print `bates: stopped myapp:web` (or with `(also stopped: …)`
parenthetical if the response's `cascaded` array is non-empty).

No `bates restart myapp:web` — the surface is `start` and `stop` only.

The dispatcher's argv check stays as `["up" | rest]` etc.; the
service-vs-app split happens inside the subcommand module by inspecting
whether the name contains a `:`. Validation:

- `bates up :web` (empty app) → usage error.
- `bates up myapp:` (empty service) → usage error.
- `bates up a:b:c` → usage error (one `:` exactly).

### Dashboard

Each service row in a multi-service application gains its own controls
column with Start and Stop buttons scoped to that service. No Restart
button (surface decision). Visibility: Start disabled when `up` or
`starting`; Stop disabled when `down`.

Single-service apps continue to render one row with one control set —
the app-level one. No per-service row appears.

New LiveView events: `start_service` / `stop_service` (each carrying
`app` and `service` params) sit as flat `handle_event` clauses next to
the existing app-level handlers.

### App GenServer surface

Add two new public functions:

```elixir
App.up(name, service_name)
App.down(name, service_name)
```

Each call goes through the same `via_tuple/1` GenServer. New
`handle_call` clauses:

- `App.up(name, service_name)` clears the `paused` flag, then walks
  the target's `depends_on` closure and starts everything in order
  via the existing `start_service/3` and dependency-readiness machinery
  (essentially `start_eligible/1` with the service set restricted to
  the closure). Blocks per Q8.
- `App.down(name, service_name)` sets the `paused` flag, then walks
  the dependents-closure in reverse topological order and stops every
  service with `pid != nil` via the existing `stop_service/3`. Returns
  the cascaded list to the caller.

The existing `App.up/1` / `App.down/1` keep their "whole-app" meaning
and now also clear / set the `paused` flag respectively. Their other
behavior is unchanged.

### Paused state — implementation sketch

A single boolean field on the `App` GenServer state (`paused: false`
initially). Set on any `:down` handler (app or service). Cleared on
any `:up` handler (app or service). Read by the loading controller
via a new `App.paused?/1` query (or folded into the existing
`App.snapshot/1`).

The loading controller's flow becomes:

1. Look up the app's `paused?` state.
2. If paused and the request is HTML: render the paused template
   (service list snapshot + Resume button posting back to the same
   URL with `?resume=true`).
3. If paused and the request is JSON: return 503 with paused body.
4. If `?resume=true` is present: call `App.up/1` (which clears the
   flag and starts everything), then fall through to the normal
   block-and-redirect flow.
5. If not paused: existing behavior unchanged.

The paused template lives alongside the existing loading template;
both render through the same controller action. No new route.

---

## What This Unlocks

1. **Database resets without addon bounces.** The motivating use case
   becomes `bates down myapp:web && mix ecto.reset && bates up
   myapp:web`. Postgres stays up; only the connection-holding service
   restarts.
2. **Focused service restarts.** Sidekiq wedged? Vite hot-reload
   confused? Restart only the broken service.
3. **Surgical crash recovery.** Today the only recovery for a crashed
   service is `bates up <app>`, which re-runs `start_eligible/1` over
   the whole app. Per-service `up` is more honest about intent and
   produces clearer dashboard transitions.
4. **A clean expression of "I know what I'm doing."** The
   application-level abstraction is right for users who think in apps;
   the per-service one is right when the user is debugging or doing
   maintenance and wants finer control.

---

## Scope

In scope:

- New `App.up/2` and `App.down/2` GenServer entrypoints (no
  `App.restart/2`).
- New `paused` state on the `App` GenServer; set on any `:down`,
  cleared on any `:up`. New `App.paused?/1` query (or fold into
  `App.snapshot/1`).
- New JSON API routes under `/processes/<app>/services/<service>/`
  for `start` and `stop` only.
- CLI parsing for the `<app>:<service>` form in `up` and `down`
  subcommands (not `restart` — app-level only). Single-line success
  output with `(also stopped: …)` parenthetical on cascade.
- Loading controller updates: render a paused-mode template when the
  app is paused; handle the `?resume=true` form post that clears
  paused and re-enters the normal blocking flow. Content-negotiate
  503 JSON for non-HTML clients.
- New paused template (HEEx) alongside the existing loading template.
  Service list snapshot, single Resume button.
- Dashboard LiveView updates: per-service Start/Stop buttons on
  multi-service apps. New `start_service` / `stop_service` events.
  Hidden on single-service apps.
- Cascade-stop machinery (reverse-topo walk over dependents-closure)
  and transitive auto-start machinery (forward walk over
  dependencies-closure). Both reuse the existing graph helpers
  (`build_dependency_graph/1`, `reverse_topological_order/1`,
  `start_eligible/1`, `start_service/3`, `stop_service/3`).
- Spec updates:
  - `specs/control-interface.md`: rewrite the "Controls" section to
    document app-level and per-service controls. Add a "Paused"
    section under Loading Page covering the paused template and
    Resume flow. Update API section with the two new endpoints
    (status-only start response, cascaded-array stop response).
  - `specs/cli.md`: extend `up` / `down` docs to cover the
    `<app>:<service>` form. Remove implication that `restart` has a
    per-service form. Document the `(also stopped: …)` cascade line.
  - `specs/process-management.md`: document cascade-stop semantics,
    transitive auto-start, and the paused flag's relationship to the
    on-demand startup flow. Note that the documented stale-export
    window (already in the spec) is structurally avoided by the
    "no per-service restart" decision.
- Tests:
  - `App` GenServer: per-service up (with auto-start of deps),
    per-service down (with cascade-stop of dependents), empty-cascade
    cases, paused-flag set/clear semantics.
  - `ProcessController`: the two new actions, including 404
    (unknown app, unknown service), 422 (crashed), 504 (timeout on
    start). Cascaded-array shape on stop.
  - `LoadingController`: paused-mode rendering (HTML), JSON 503
    response, Resume flow restoring the normal block-and-redirect.
  - CLI subcommand modules: `<app>:<service>` parsing, success paths,
    error paths, cascade-line rendering.
  - Dashboard: button visibility for single- vs multi-service apps;
    per-service control rendering for multi-service. LiveView render
    assertion is enough — no full click-through.
  - Test fixture: extend `test/fixtures/multi_service_config.toml`
    with the dependency-chain scenarios needed for cascade and
    auto-start coverage.

Out of scope:

- **Per-service `restart` command.** Structurally dropped per Q3.
  Users compose `down` + `up`.
- **Per-service `env` command.** `bates env <app>` already returns the
  union of exports for the application. Per-service env would be a
  separate decision; defer.
- **Per-service `logs` command.** The existing `/processes/<app>/logs`
  endpoint already returns per-service log buffers; the CLI doesn't
  expose it yet. Per-service logs is its own feature, not entangled
  with start/stop.
- **Selective on-demand startup.** The loading page either runs the
  normal start flow or shows paused — no per-service intent flag at
  the loading layer.
- **Cross-app dependencies.** Same as the original ordering proposal —
  intra-app only.
- **A `--cascade` / `--no-cascade` flag.** Cascade is the only
  behavior; no knob.
- **Confirmation modals on the dashboard.** Live status reflects
  cascade transitions in real time; that's enough.
- **Persisting the paused flag across `batesd` restarts.** In-memory
  only.

---

## Open Questions

None remaining. All seven original open questions plus seven additional
questions surfaced during the 2026-05-18 refinement Q&A were resolved
and folded into the **Decided** section above. Key shifts from the
draft:

- **Per-service `restart` was dropped entirely** (new Q3). The
  surface is `start` and `stop` only; users compose them to avoid the
  stale-export window.
- **Paused state was added** (Q5, originally framed around Caddy
  route lifecycle). Any user-initiated `down` pauses the app; the
  loading page renders a paused template with a Resume button when
  hit. This was the breaking change: without it, polling browsers
  would auto-restart whatever the user just stopped.
- **No confirmation modal on the dashboard** (Q7). Live PubSub
  status communicates the cascade.

The full Q&A discussion is in the chat transcript; the **Decided**
section above is the authoritative record.

