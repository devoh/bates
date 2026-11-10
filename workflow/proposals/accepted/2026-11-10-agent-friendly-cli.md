# Agent-Friendly CLI — Proposal

**Status:** Accepted
**Date:** 2026-11-10
**Author:** Tyler + Claude
**Accepted:** 2026-11-10

## Summary

Make the `bates` CLI tell a caller what happened without a second
terminal. Three changes:

1. **`bates logs`** exposes the per-service ring buffer from the CLI.
2. **Crash output in failures.** Failed `up`, `restart`, and `env`
   commands print a short reason plus the tail of the crashed
   service's log. `restart` now blocks until the application settles,
   like `up`, instead of reporting success as soon as it spawns.
3. **`bates info [<name>]`** shows one application's root and each
   service's `https://` URL, port, and status. With no name, it uses
   the current directory's application, like the other commands.

The motivating caller is an AI coding agent working inside an
application directory. It can run commands and read their output, but
it can't see the terminal running `batesd`. The same changes help a
human who started `batesd` in a tab they aren't looking at.

## Problem

When an application managed by Bates misbehaves, the only full view of
what happened is the interleaved stream on `batesd`'s stdout. From the
CLI:

- **There's no way to read logs.** `GET /processes/<name>/logs` exists
  and `specs/process-management.md` names `bates logs myapp:web` as the
  intended consumer, but the command was never built. The endpoint
  also raises (500) for an unknown application instead of returning a
  JSON 404, because `App.logs/1` calls an unregistered name.
- **Crash output is inconsistent.**
  - `bates up myapp:web` puts the service's *entire* buffer (up to
    1,000 lines) in `reason`, because the per-service crash broadcast
    carries `drain_log_buffer/1` as its reason.
  - `bates up myapp` reports `service web failed: :crashed`. The exit
    code is discarded by `extract_exit_status/1`, and no log output is
    included.
  - `bates restart myapp` returns 200 as soon as `App.up/1` returns,
    so it prints `bates: restarted myapp` even when the application
    crashes a second later.
- **Logs mix runs.** The ring buffer is never cleared when a service
  starts, so after a restart the buffer holds the previous run's
  output followed by the current one, with no separator. A caller
  can't tell whether an error is current.
- **Finding the URL takes guesswork.** `bates status` lists every
  application, and hostnames appear without a scheme. A caller in an
  application directory has to know the application's name to find
  its row, and then has to know Bates serves HTTPS.

## Decided

### `bates logs`

- **Target forms match `bates up`:** `<app>`, `<app>:<service>`,
  `:<service>` (current-directory application), or no argument
  (current-directory application). More than one colon exits 2.
- **`--lines N`** limits output to the last N lines per service.
  Default 100. The buffer's 1,000-line cap still applies.
- **Output:** for a single service, lines are printed bare. For
  several services, each line is prefixed with `[<service>] ` and
  output is grouped by service in configuration order. The buffer is
  per-service, so there's no cross-service time ordering to preserve.
- **No `--follow`.** A blocking stream is awkward for agents and for
  the escript's `:httpc` client. Repeated calls cover the need.
- **Daemon owns filtering.** The CLI passes `lines` and the service
  name to the API rather than trimming client-side, so a rewritten CLI
  gets the same behavior for free.

### Crash output

- **`reason` is one line.** It names the service and its exit code:
  `service web exited with status 1`. `extract_exit_status/1` keeps
  the code instead of collapsing it to `:crashed`.
- **A new `logs` field carries the tail.** Every 422 crash response
  from the start, service start, restart, and env endpoints includes
  `"logs": {"service": "web", "lines": [...]}` with the last 20 lines
  of the first crashed service (alphabetical, matching
  `crash_reason/2`).
- **The CLI prints both to stderr:** the reason, then the lines
  indented by two spaces. Exit code stays 1.
- **`restart` blocks.** The endpoint stops the application, then
  follows the same path as `start` (subscribe, start, await settle).
  It returns the same responses as `start`: 200 with `exports`, 422
  with `reason` and `logs`, or 504 on timeout.

### Buffer reset

- **The ring buffer is cleared when a service starts.** Crash output
  is drained into the broadcast at exit, before any restart, so the
  loading page loses nothing. `bates logs` then always shows the
  current run, or the last run if the service is down or crashed.

### `bates info [<name>]`

- **A new command, not a `status` argument.** Every other command
  treats a missing name as "the current directory's application."
  `bates status` can't, because with no name it has to keep listing
  everything, so scoping it would need a new convention like
  `bates status .` that nobody would guess. `status` stays unchanged.
- **Target forms:** `<app>` or no argument (current directory, through
  `/apps/resolve`). `<app>:<service>` exits 2. An unknown name exits 1
  with `unknown application: <name>`.
- **Scope is identity and reachability:** name, root, derived status,
  and per-service URL (`https://<hostname>`), status, and port.
  Exports belong to `bates env` and output to `bates logs`. Keeping
  `info` this narrow stops it from drifting into a second `status`.
- **Output is key-value for the application, then a service table:**

  ```
  $ bates info
  name:   myapp
  root:   /Users/thunt/Work/myapp
  status: up
  services:
    web     https://myapp.test       up   52341
    vite    https://vite.myapp.test  up   52342
    worker                           up   —
  ```

- **`/status` gains `root`.** `/apps/resolve` only looks up by path,
  so a named `bates info myapp` has no other source for the root. The
  field is additive and expanded (no `~`), so a caller can compare it
  with its working directory. The CLI picks the application's entry
  from the list; no new endpoint.

## Proposed Design

### API

```
GET /processes/<app>/logs?lines=N
GET /processes/<app>/services/<service>/logs?lines=N

→ 200  {"name": "myapp", "services": [{"name": "web", "lines": [...]}]}
→ 404  {"name": "myapp", "status": "unknown", "reason": "..."}
→ 400  {"status": "invalid", "reason": "lines must be a positive integer"}
```

The per-service route mirrors the start and stop nesting and returns
the same envelope with one service.

Each `/status` entry gains `root`:

```
{"name": "myapp", "root": "/Users/thunt/Work/myapp", "status": "up",
 "services": [...]}
```

Crash responses gain `logs`:

```
→ 422
{
  "name": "myapp",
  "status": "crashed",
  "reason": "service web exited with status 1",
  "logs": {"service": "web", "lines": ["...", "..."]}
}
```

### `App` GenServer

- `logs/2` takes an optional `lines` limit and an optional service
  name. It returns `{:error, :unknown_service}` for a bad service name.
  The controller checks `ProcessSupervisor.app_pid/1` first, as `start`
  does, so an unknown application gets a 404 rather than an exit.
- `snapshot/1` adds a `logs` entry alongside `reason`, built from the
  same service `crash_reason/2` picks.
- The per-service `{:status, "crashed", output}` broadcast is
  unchanged: `LoadingLive` renders `output` as its crash view. The
  controller ignores the payload and builds `reason` and `logs` from
  the snapshot instead.

### CLI

- `Bates.CLI.Logs` follows the `Up` module's target parsing. That
  parsing is now duplicated across `Up`, `Down`, and `Logs`, so it
  moves into one shared function.
- A single helper formats an error body (reason plus indented log
  lines) and is used by `Up`, `Restart`, and `Env`.
- `Bates.CLI.Info` resolves the name the same way `Restart` does,
  then renders its entry from `/status`.

### Specs

Update `specs/cli.md` (new `logs` and `info` commands, `restart`
blocking), `specs/control-interface.md` (logs endpoints, `logs`
field, `root` in `/status`, `restart` behavior), and
`specs/process-management.md` (buffer reset on start).

## Scope

In scope: the three changes above and their specs.

Out of scope:

- `bates logs --follow`.
- `--json` output flags. Callers that want structured data can
  request the API directly.
- Changes to the dashboard.
- Persisting logs to disk.

## Open Questions

None.
