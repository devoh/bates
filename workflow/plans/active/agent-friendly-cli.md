# Plan: Agent-Friendly CLI

**Goal:** Add `bates logs` and `bates info`, include a log tail in
crash responses, and make `bates restart` block until the application
settles.

**Proposal:** [`workflow/proposals/accepted/2026-11-10-agent-friendly-cli.md`](../proposals/accepted/2026-11-10-agent-friendly-cli.md)

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-11-10 | Plan created from accepted proposal. Four phases, one commit each, specs updated alongside code. |

## Why This Matters

A caller that can't see `batesd`'s terminal (an AI agent, or a human
in another tab) currently can't read logs, gets crash reasons like
`service web failed: :crashed`, is told `restarted` when the restart
crashed, and has to guess an application's URL.

## Acceptance Criteria

- [ ] `bates logs` in an application directory prints that
      application's recent output; `bates logs myapp:web --lines 5`
      prints at most five unprefixed lines.
- [ ] `GET /processes/ghost/logs` returns a JSON 404, not a 500.
- [ ] After a service restarts, its buffer holds only the new run's
      output.
- [ ] `bates up myapp` against a service running `exit 3` prints
      `service <name> exited with status 3` followed by its last log
      lines, and exits 1. Same for `bates up myapp:<service>`,
      `bates restart`, and `bates env` (for addons).
- [ ] `bates restart myapp` exits 1 with crash output when the
      application crashes on start, and 0 only once it has settled.
- [ ] The loading page's crash view is unchanged.
- [ ] `bates info` in an application directory prints its name,
      expanded root, status, and per-service `https://` URLs, status,
      and ports. `bates info ghost` exits 1; `bates info a:b` exits 2.
- [ ] `bates status` output is unchanged.
- [ ] `mix test` passes.

## Phase 1 — `bates logs`

**Files:** `source/lib/bates/app.ex`,
`source/lib/bates_web/router.ex`,
`source/lib/bates_web/controllers/process_controller.ex`,
`source/lib/bates/cli.ex`, `source/lib/bates/cli/logs.ex` (new),
`source/lib/bates/cli/up.ex`, `source/lib/bates/cli/down.ex`, their
tests, `specs/cli.md`, `specs/control-interface.md`,
`specs/process-management.md`.

1. **Buffer reset.** In `App.start_service/3`, set
   `log_buffer: :queue.new(), log_count: 0` on the new service state
   alongside `exit_status: nil`. Crash output is drained in the
   `:EXIT` handler before this runs, so `LoadingLive` is unaffected.
2. **`App.logs/2`.** `logs(name, opts)` with `:lines` and `:service`.
   Trims each service's list to the last N lines inside the
   GenServer. Returns `{:ok, services}` or `{:error, :unknown_service}`.
   Services are ordered as configured (`state.services` is a map, so
   order by the config list, not map iteration). Keep `logs/1` as
   `logs(name, [])` only if something else calls it; otherwise
   replace it.
3. **Endpoints.** `logs` checks `fetch_app/1` first (404 JSON for an
   unknown app). Parse `lines`: absent means all; a positive integer
   is passed through; anything else is a 400 with
   `{"status": "invalid", "reason": "lines must be a positive integer"}`.
   Add `get "/processes/:app/services/:service/logs"` returning the
   same envelope with one service, or 404 for an unknown service.
4. **Shared target parsing.** Move `Up.parse/1` (the
   `{:app, _} | {:service, _, _} | {:cwd_service, _} | :invalid`
   function) and the cwd resolution around it into one place
   (`Bates.CLI.Target` or a function on `Client`; pick whichever
   reads cleaner) and use it from `Up`, `Down`, and `Logs`. Existing
   `Up` and `Down` tests must pass unchanged.
5. **`Bates.CLI.Logs`.** `run(argv)` takes `[]`, `[target]`, and
   `--lines N` in either position (use `OptionParser` with
   `strict: [lines: :integer]`). Default 100. Invalid options or more
   than one target exit 2. Print lines bare for one service, or
   `[<service>] <line>` for several. Error bodies go to stderr, exit 1.
6. **Dispatcher and usage.** Add `logs` to `Bates.CLI.dispatch/1` and
   the usage text.

**Tests:** controller (404 for unknown app and service, 400 for bad
`lines`, `lines` trims, per-service route); `App` (buffer cleared on
restart); CLI with Bypass (bare vs. prefixed output, `--lines` sent
as a query parameter, cwd resolution, exit codes).

**Specs:** add `bates logs` to `specs/cli.md` (including the Working
Directory Resolution list); document both endpoints and the 404/400
in `specs/control-interface.md`; note the reset-on-start in the
Logging section of `specs/process-management.md` and drop "can be
exposed via the API" wording that's now just true.

## Phase 2 — Crash output

**Files:** `source/lib/bates/app.ex`,
`source/lib/bates_web/controllers/process_controller.ex`,
`source/lib/bates/cli/client.ex`, `source/lib/bates/cli/up.ex`,
`source/lib/bates/cli/env.ex`, their tests,
`specs/control-interface.md`, `specs/cli.md`.

1. **Keep the exit code.** `extract_exit_status/1` maps
   `{:exit_status, raw}` through `:exec.status/1`, which returns
   `{:status, code}` or `{:signal, signal, core_dumped?}`; store
   `{:status, code}` or `{:signal, signal}`. `service_status_name/1`
   still treats anything other than `nil`/`:normal` as crashed.
2. **One-line reasons.** `crash_reason/2` and `addon_crash_reason/2`
   render `service web exited with status 1`,
   `service web was killed by signal <sig>`, or (for `:timeout`)
   `service web did not become ready in time`. Use "addon" in place
   of "service" for the addon variant, as today.
3. **`logs` in snapshots.** `build_snapshot/1` and
   `build_addon_snapshot/1` add
   `logs: %{service: name, lines: last_20}` for the same service the
   reason names, or `nil`. Extract one function that picks the
   crashed service so reason and logs can't disagree.
4. **Controller.** Every crash 422 (app start, service start, env)
   reads the snapshot and returns `reason` and `logs`. In
   `receive_settled`, `receive_service_settled`, and the snapshot
   branches, stop using the broadcast payload as `reason`; the
   per-service broadcast itself is unchanged because `LoadingLive`
   renders it. For the service start 422, the named service may not
   be the one that crashed (a dependency can crash first), so the
   snapshot's pick is correct.
5. **CLI error formatting.** One function in `Client` (for example
   `Client.error_message(body)`) returns
   `reason || error || "request failed"`, followed by
   `"  " <> line` for each entry in `body["logs"]["lines"]`. Use it
   from `Up`, `Env`, and (in Phase 3) `Restart`. Replace the inline
   `body["reason"] || ...` expressions it duplicates in those
   modules; leave `Status` and `Down` alone unless they share the
   same expression verbatim.

**Tests:** controller 422s include `reason` matching
`~r/exited with status 1/` and a `logs` map (the existing crash
fixtures use `exit 1` and `/bin/false`); an echo-then-exit fixture
(`echo boom; exit 3`) proves the tail contains `boom` and the code is
3; `App` unit test for the signal and timeout reasons if a fixture
can produce them cheaply. CLI tests assert indented lines on stderr.

**Specs:** `logs` field and reason format in
`specs/control-interface.md`; failure output in `specs/cli.md` under
`up` and `env`.

## Phase 3 — Blocking restart

**Files:** `source/lib/bates_web/controllers/process_controller.ex`,
`source/lib/bates/cli/restart.ex`, their tests,
`specs/control-interface.md`, `specs/cli.md`.

1. **Controller.** `restart` does `fetch_app/1` (404), then
   `App.down/1` (422 with `error` on failure, as today), then
   subscribes to `"app:#{name}"` and calls the same
   `await_start_response/2` path `start` uses. Subscribe after `down`
   returns so stale `down` broadcasts don't race the wait; the
   snapshot check in `await_start_response/2` covers anything missed.
2. **CLI.** `Restart` uses the Phase 2 error formatter. Success
   output stays `bates: restarted <name>`. The client's 65-second
   timeout already covers the 60-second readiness wait.

**Tests:** existing restart tests still pass (now with `exports` in
the body); new test: restart of a crashing service returns 422 with
`reason` and `logs`; 404 for unknown app.

**Specs:** restart response shapes in `specs/control-interface.md`;
blocking behavior in `specs/cli.md` under `bates restart`.

## Phase 4 — `bates info`

**Files:** `source/lib/bates_web/controllers/process_controller.ex`,
`source/lib/bates/app.ex` (if root isn't already reachable),
`source/lib/bates/cli.ex`, `source/lib/bates/cli/info.ex` (new),
tests, `specs/cli.md`, `specs/control-interface.md`.

1. **`root` in `/status`.** Add `root: Path.expand(root)` to each
   entry. The root is in `App` state (`state.root`); expose it through
   an existing call if one returns it, otherwise add `App.root/1`.
2. **`Bates.CLI.Info`.** `run/0` resolves the cwd (same as
   `Restart.run/0`), `run(name)` rejects names containing `:` with
   exit 2, then GETs `/status` and finds the entry. Missing entry:
   `unknown application: <name>` on stderr, exit 1.
3. **Rendering.** `name:`, `root:`, `status:` lines aligned on the
   value, then `services:` and an indented, column-aligned table of
   name, URL (`https://<hostname>` or blank), status, and port (`—`
   for nil). No header row. Reuse `Status`'s width calculation only
   if it can be shared without changing `Status`'s output; otherwise
   write the few lines `Info` needs.
4. **Dispatcher and usage.** Add `info` to `Bates.CLI.dispatch/1`
   and the usage text.

**Tests:** controller `/status` includes an expanded `root`; CLI
with Bypass for cwd resolution, named lookup, unknown name, colon
rejection, and the rendered output (single- and multi-service).

**Specs:** `bates info` in `specs/cli.md` (and the Working Directory
Resolution list); `root` in the `/status` example in
`specs/control-interface.md`.

## What Does NOT Change

- `bates status` output and the `/status` fields it reads.
- The per-service crash broadcast payload and `LoadingLive`.
- The dashboard.
- The `/apps/resolve` endpoint.

## Where to Start

Run `mix test` from `source/` for a baseline. Phase 1 step 4 (shared
target parsing) is a refactor; land it inside Phase 1's commit only
after `Up` and `Down` tests pass against it.
