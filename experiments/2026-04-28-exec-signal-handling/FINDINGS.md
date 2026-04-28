# Findings — exec Prefix Signal Handling

**Date:** 2026-04-28
**Assumption:** When `:exec.run_link/2` is given `sh -c 'prologue; exec <cmd>'`, the shell `exec` builtin replaces `sh` with `<cmd>` so the returned OS PID is `<cmd>` and signals reach it directly.
**Result:** Confirmed.

## Test

With `exec` prefix (`sh -c 'echo started; exec sleep 30'`):

- `os_pid = 3294`
- `ps -o pid,command -p 3294` → `3294 sleep 30` (no shell wrapper)
- `pgrep -P 3294` → empty (no children — `sleep` is a leaf)
- `:exec.kill(pid, 15)` → `:ok`; exit message `{:exit_status, 15}` arrives in ~0 ms

Without `exec` prefix (`sh -c 'echo started; sleep 30'`, control):

- `os_pid = 3325`
- `ps -o pid,command -p 3325` → `3325 sh -c echo started; sleep 30`
- `pgrep -P 3325` → `3326` (child `sleep`)
- erlexec still cleans up via tracked children, but `sh` sits between the
  signal and the service.

## Bonus Observation

erlexec links the worker to the calling process. `{:EXIT, _, {:exit_status, _}}`
propagates on stop. `Bates.App` already calls `Process.flag(:trap_exit, true)`
in `init/1`, so this is handled.

## Impact on Plan

None. The plan's `prologue1; prologue2; exec <command>` shape, passed as a
single `sh -c` to `:exec.run_link/2`, satisfies the "signals reach the
service directly" acceptance criterion.

## Artifacts

- `explore.exs`
- `raw/output.txt`
