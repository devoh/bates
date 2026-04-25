# Readiness Checks - Proposal

**Status:** Accepted
**Date:** 2026-04-24
**Refined:** 2026-04-24
**Author:** Tyler + Claude

## Summary

Add TCP-based readiness checks so Bates knows when a process is
actually accepting connections, not just spawned. The loading page
currently redirects the moment the OS process starts, which usually
lands on a connection refused error because the app hasn't bound its
port yet.

---

## Problem

Today, `Process.up/1` broadcasts `{:status, "up"}` immediately after
`:exec.run_link` succeeds. This means "the OS process exists," not
"the app is listening." For a Rails server that takes several seconds
to boot, the loading page redirects while the app is still
initializing. The user hits a Caddy 502, which triggers the fallback
again, creating a loop between the loading page and the error handler
until the app finally starts.

---

## Decided

- **TCP polling, not stdout sniffing.** Readiness is determined by
  whether a TCP connection to the assigned port succeeds. Parsing
  stdout for "Listening on..." patterns is fragile and
  framework-specific. TCP is universal.
- **Only for services with a port.** Services without a port (workers,
  background jobs) have no readiness check. They are considered ready
  immediately after the OS process starts. This is already specified.
- **The Process GenServer owns readiness.** The polling loop runs
  inside the Process GenServer after `:exec.run_link` succeeds, not
  in the LiveView or a separate process. This keeps lifecycle concerns
  in one place.
- **`Process.up/1` returns immediately.** After spawning the OS
  process, `up/1` returns `:ok` without waiting for the TCP check.
  Readiness is communicated async via PubSub. This avoids blocking
  the LiveView mount and API endpoints during boot.
- **"starting" is a formal lifecycle state.** The spec's lifecycle
  table gains a fourth state. The API, loading page, and future
  dashboard all treat it as a distinct, user-visible state.
- **`down` works during "starting."** If the user stops an app before
  it becomes ready, the OS process is stopped and readiness polling
  is cancelled. `down` works in any state where an OS process exists.
- **Poll interval: 200ms.** Hardcoded. Fast enough to be
  imperceptible on localhost, not worth making configurable.
- **Readiness timeout: 60 seconds.** Hardcoded. Matches the existing
  GenServer call timeout. Configurable per-process only if someone
  hits the limit.
- **No loading page visual changes.** The existing "Starting
  application..." display covers the "starting" state. The only
  difference is that the redirect fires later (after TCP check
  instead of after spawn).

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted
> or executed. These are pointers to help orient, not implementation
> instructions.

- **Process GenServer** (`source/lib/bates/process.ex`) — Manages
  the OS process lifecycle. `handle_call(:up, ...)` starts the process
  and broadcasts `{:status, "up"}` immediately. State tracks `pid`,
  `exit_status`, and a log buffer. The `status_name/1` helper derives
  status from whether `pid` is set.
- **Loading LiveView** (`source/lib/bates_web/live/loading_live.ex`)
  — Subscribes to PubSub topic `process:<name>`. Redirects on
  `{:status, "up"}` or if status is `"up"` at mount time. Shows crash
  details on `{:status, "crashed", log_output}`.
- **PubSub broadcasts** — Process GenServer broadcasts on
  `process:<name>` for state transitions: `{:status, "up"}`,
  `{:status, "down"}`, `{:status, "crashed", log_output}`.
- **Process struct** — Has a `port` field (0 means auto-assign). Port
  is assigned at init via `PortNumber.next/0`.
- **Tests** — `test/bates_web/live/loading_live_test.exs` covers
  redirect on PubSub message, redirect on mount when already up, and
  redirect when process starts during mount.

---

## Proposed Design

Introduce a new lifecycle state between "spawned" and "up." After
`:exec.run_link` succeeds, the Process GenServer enters a "starting"
state and begins polling the assigned port with a TCP connect attempt.
When the connection succeeds, it transitions to "up" and broadcasts.

The state progression:

```
down → starting → up
               → crashed (if process exits before becoming ready)
```

The Process GenServer uses `Process.send_after/3` to schedule poll
ticks. Each tick attempts `:gen_tcp.connect` to `127.0.0.1:<port>`
with a short timeout. On success, it transitions to "up" and
broadcasts. On failure, it schedules the next tick.

If the OS process exits while in "starting" (the EXIT message arrives
before a successful TCP connect), the process transitions to "crashed"
as it does today.

A global timeout prevents polling forever if the app never starts
listening. After the timeout, the process is stopped and transitions
to "crashed" with a message indicating the app failed to bind its
port.

The `{:status, "up"}` broadcast only fires after the readiness check
passes, not when the OS process is spawned. This means the loading
page, PubSub subscribers, and `Process.status/1` all reflect whether
the app is actually reachable.

For processes without a port (port is 0 and not auto-assigned), the
current behavior is preserved: "up" immediately after spawn.

---

## What This Unlocks

1. The loading page redirect lands on a working application instead of
   a 502 error.
2. The `GET /status` API accurately reflects whether an app is
   reachable, not just spawned.
3. A future dashboard can show "starting" as a distinct state with
   meaningful progress indication.

---

## Scope

- New "starting" state in Process GenServer with TCP polling loop
- Delayed `{:status, "up"}` broadcast until readiness confirmed
- New `{:status, "starting"}` broadcast when OS process is spawned
- Readiness timeout with error reporting
- Update existing tests, add readiness-specific tests
- No changes to Caddy configuration
- No changes to the API endpoints
- No changes to PortNumber

---

## Open Questions

None. All questions resolved during refinement.
