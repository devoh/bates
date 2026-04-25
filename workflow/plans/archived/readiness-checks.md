# Plan: Readiness Checks

**Goal:** Delay the "up" broadcast until the process is actually
accepting TCP connections, so the loading page redirects to a working
application.

**Proposal:** [Readiness Checks](../proposals/accepted/2026-04-24-readiness-checks.md)

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-04-24 | Plan created from accepted proposal. |
| 2026-04-24 | Audit: add Phase 4 (spec updates), add acceptance criterion for port 0 edge case, add guard in Phase 2 for portless processes. |

## Why This Matters

The loading page redirects the moment the OS process spawns, before
the application has bound its port. The user hits a 502 and loops
back to the loading page. Readiness checks fix this by polling the
assigned port and only broadcasting "up" once a TCP connection
succeeds.

## Acceptance Criteria

- [ ] `Process.up/1` returns `:ok` immediately after spawning the OS
      process, without waiting for readiness
- [ ] After spawning, `Process.status/1` returns `"starting"` (not
      `"up"`)
- [ ] A `{:status, "starting"}` PubSub broadcast fires when the OS
      process is spawned
- [ ] The Process GenServer polls `127.0.0.1:<port>` every 200ms via
      TCP connect
- [ ] When the TCP connect succeeds, status transitions to `"up"` and
      `{:status, "up"}` is broadcast
- [ ] If the OS process exits while in `"starting"`, status
      transitions to `"crashed"` with log output
- [ ] If 60 seconds elapse without a successful TCP connect, the
      process is stopped and transitions to `"crashed"` with a
      timeout message
- [ ] `Process.down/1` works while in `"starting"` — stops the OS
      process and cancels polling
- [ ] Processes without a port (port 0, not auto-assigned) transition
      to `"up"` immediately after spawn with no polling
- [ ] The loading page still redirects on `{:status, "up"}` (no
      loading page changes needed)
- [ ] Specs updated: `process-management.md` lifecycle table,
      `control-interface.md` loading page flow,
      `system-overview.md` on-demand startup flow
- [ ] Existing tests updated, new readiness-specific tests added
- [ ] `mix test` passes

## Phases

### Phase 1: Add "starting" state to Process GenServer

Add a `ready` field to the GenServer state to distinguish "spawned"
from "ready." Update `status_name/1` to return `"starting"` when
`pid` is set but `ready` is false.

**Files to update:**
- `source/lib/bates/process.ex` — Add `ready: false` to the state
  map in `init/1`. Update `status_name/1` to check `ready`:
  - `pid` is set and `ready` is true → `"up"`
  - `pid` is set and `ready` is false → `"starting"`
  - `pid` is nil, exit clean/nil → `"down"`
  - otherwise → `"crashed"`

  In `handle_call(:up, ...)`, after `:exec.run_link` succeeds:
  - Set `pid` on state but leave `ready: false`
  - Broadcast `{:status, "starting"}` instead of `{:status, "up"}`
  - Reply `:ok` immediately

  In `handle_call(:down, ...)`, reset `ready: false` alongside
  `pid: nil`.

**Verify:** `mix compile` succeeds. `Process.up/1` returns `:ok`,
`Process.status/1` returns `"starting"`, and `{:status, "up"}` is
never broadcast.

### Phase 2: TCP readiness polling

After spawning the OS process, schedule a readiness poll. On each
tick, attempt a TCP connect. On success, transition to "up."

**Files to update:**
- `source/lib/bates/process.ex` — Add module attributes for poll
  interval (`@poll_interval 200`) and readiness timeout
  (`@readiness_timeout 60_000`).

  At the end of `handle_call(:up, ...)` (after setting pid and
  broadcasting "starting"), schedule the first poll with
  `Process.send_after(self(), :check_ready, @poll_interval)` and
  record the start time in state (`started_at: System.monotonic_time(:millisecond)`).

  Add `handle_info(:check_ready, state)`:
  - Attempt `:gen_tcp.connect(~c"127.0.0.1", port, [], 100)`
  - On `{:ok, socket}`: close the socket, set `ready: true`,
    broadcast `{:status, "up"}`
  - On `{:error, _}`: check elapsed time against
    `@readiness_timeout`. If exceeded, stop the OS process and
    broadcast `{:status, "crashed", "Timed out waiting for port <port>"}`.
    Otherwise, schedule the next poll.
  - Only poll when `pid` is set and `ready` is false (guard against
    stale messages after `down`).
  - Guard for portless processes: if the process has no port (port 0,
    not auto-assigned), skip polling entirely — set `ready: true` and
    broadcast `{:status, "up"}` immediately after spawn.

**Verify:** Start a process with the test server. `status` returns
`"starting"` briefly, then `"up"` once the server binds its port.
PubSub subscribers receive `"starting"` then `"up"`.

### Phase 3: Update tests

Update existing tests to account for the new "starting" state and
add tests for the readiness polling behavior.

**Files to update:**
- `source/test/bates_web/live/loading_live_test.exs` — The
  "redirects when process starts during mount" test will change
  behavior: `Process.up` no longer triggers an immediate "up"
  broadcast, so the LiveView won't redirect during mount. Instead
  it mounts successfully with status "starting" and redirects when
  the PubSub "up" message arrives. Update accordingly.

  The "redirects when process is already running" test needs the
  process to be fully ready (not just spawned). This requires
  waiting for the TCP check to pass, or manually setting the
  process state.

  The "redirects when process comes up after mount" test should
  still work as-is (it sends a manual PubSub broadcast).

**Files to create:**
- `source/test/bates/process_readiness_test.exs` — Test the
  readiness polling:
  - Process status is "starting" immediately after `up/1`
  - Process transitions to "up" when the port is listening
  - Process transitions to "crashed" on readiness timeout
  - `down` works while in "starting" state
  - PubSub broadcasts fire for each transition

  These tests need a way to control when the port starts
  listening. A simple approach: start a TCP listener in the test
  after calling `Process.up/1`, then assert the transition.

**Verify:** `mix test` passes. All existing and new tests green.

### Phase 4: Update specs

Update the specs to reflect the new "starting" lifecycle state and
its effect on the loading page and on-demand startup flows.

**Files to update:**
- `specs/process-management.md` — Add "starting" to the lifecycle
  table. Update the state diagram to show the
  `down → starting → up` progression and the
  `starting → crashed` transition (timeout or process exit).
- `specs/control-interface.md` — Update the loading page flow to
  note that the redirect fires on `{:status, "up"}` which now
  occurs after the TCP readiness check, not immediately after
  spawn.
- `specs/system-overview.md` — Update the on-demand startup flow
  description to include the readiness polling step between
  process spawn and the "up" state.

**Verify:** Read each updated spec and confirm it accurately
describes the implemented behavior.

## What Does NOT Change

- Caddy configuration (no routing changes)
- API endpoints (they return whatever `Process.status/1` returns)
- Loading page template (already handles "starting" via the else
  branch)
- PortNumber module
- ProcessSupervisor
- Config parsing

## Where to Start

> These are pointers from the codebase survey at plan creation time.
> Files may have changed by execution time. Verify before acting.

**Core flow to trace:**
- `Process.handle_call(:up, ...)` at line 56 — where the OS process
  is spawned and the broadcast fires. This is the primary change
  point.
- `status_name/1` at line 158 — derives status from state. Needs a
  new clause for "starting."
- `handle_info({:EXIT, ...})` at lines 107 and 113 — crash handling.
  Should work unchanged since it checks `pid` and `exit_status`.

**Loading page flow:**
- `LoadingLive.mount/3` — calls `Process.up` then checks
  `Process.status`. With this change, status will be "starting"
  instead of "up" during mount, so the mount-time redirect won't
  fire. The PubSub redirect path handles it.
- `LoadingLive.handle_info({:status, "up"}, ...)` — redirect. No
  changes needed.

**Existing test files:**
- `test/bates_web/live/loading_live_test.exs` — 3 tests, 2 need
  updating
- `test/bates/port_number_test.exs` — unaffected
- `test/support/conn_case.ex` — unaffected
- `test/support/test_server.ex` — useful for readiness tests (it
  binds to `$PORT` and accepts connections)

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-04-24 | READY FOR AUTONOMOUS EXECUTION | No blockers. Added Phase 4 (spec updates), port 0 guard to Phase 2, and acceptance criteria for both. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

All dependencies are in place, no open questions remain, and no
pre-work is required. The plan can be executed autonomously via
`/execute-plan`.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| Test server fixture | Ready | `test/support/test_server.ex` exists, binds to `$PORT` and accepts TCP connections |
| Test helper | Ready | `test/support/conn_case.ex` exists with LiveView test support |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `:gen_tcp` | Available | Part of Erlang/OTP stdlib, no additional dependency needed |
| `:exec` (erlexec) | Installed | Already in `mix.exs` and used by `Process` GenServer |
| Phoenix PubSub | Installed | Already in supervision tree and used for broadcasts |
| Phoenix LiveView | Installed | Already used by `LoadingLive` |

### Open Questions

None. All design decisions were resolved during proposal refinement.

### POC Gaps

| # | Assumption | Status | Notes |
|---|-----------|--------|-------|
| 1 | `:gen_tcp.connect` with 100ms timeout is sufficient for localhost readiness check | Trivially verifiable | Standard OTP function, localhost latency is sub-millisecond |
| 2 | `Process.send_after/3` messages are discarded after `down` resets state | Verifiable during execution | Guard clause in `handle_info(:check_ready)` handles stale messages |

### Pre-Work

None required.

### Blockers

None identified.
