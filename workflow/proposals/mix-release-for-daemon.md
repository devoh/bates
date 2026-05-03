# Mix Release for the Daemon — Proposal

**Status:** Draft
**Date:** 2026-05-02
**Refined:** 2026-05-03
**Author:** Tyler + Claude
**Origin:** Hand-test of `bates start` (PR [#31](https://github.com/tylerhunt/bates/pull/31), since merged) failed with an `erlexec` priv-dir lookup error. Supersedes the `bates start` portions of the accepted [Add CLI Commands proposal](accepted/2026-05-01-add-cli-commands.md).

## Summary

Split the `bates` binary in two. Keep `bates` as an escript for the control commands (`env`, `status`, `up`, `down`, `restart`, `setup`) — they need fast cold-start and only speak HTTP to a running daemon. Ship the daemon as a Mix release named `batesd`, which embeds ERTS and includes priv directories so `erlexec` can find its `exec-port` C binary at runtime.

The merged `bates start` subcommand is removed. Users invoke `batesd` directly to start the server. Eventually a follow-up proposal will install a launchd job via `bates setup` so users don't run `batesd` by hand in normal use, but that is explicitly out of scope here.

## Problem

The merged `bates start` command (PR #31, Phase 4 of the Add-CLI-Commands plan) does not work outside of `mix phx.server`. Hand-testing the built escript exposes the failure:

```
$ ./bates start
[warning] No exec-port files found in
  ~c"/Users/thunt/Work/bates/bates/source/bates/erlexec/priv" directory

[notice] Application erlexec exited: :exec_app.start(:normal, [])
  returned an error: shutdown: failed to start child: :exec
    ** (EXIT) bad return value: ~c"Cannot find file : no such file or directory"

bates: failed to start erlexec: ...
```

**Root cause.** Escripts package `.beam` files into a single ZIP archive but do **not** package `priv/` directories from dependencies. `erlexec` needs `priv/exec-port` (a compiled C binary) at runtime. `code:priv_dir(:exec)` returns `:bad_directory` inside an escript, and erlexec's fallback computes a path that doesn't exist on disk.

This is the materialization of POC gap #2 from the readiness audit:

> POC #2: `Application.ensure_all_started(:bates)` from inside an escript boots the supervision tree without lock contention against the test app — Safe to verify during Phase 4 hand-testing; if it fails, fall back to `Bates.Application.start(:normal, [])` directly.

The audit framed it as a startup-mechanism issue. It's actually a packaging issue: the escript format can't carry `erlexec`'s native dependency.

**Why we can't drop erlexec.** `Bates.App` (`source/lib/bates/app.ex`) uses `:exec.run_link/2`, `:exec.kill/2`, `:exec.stop/1`, and the `{:stdout, os_pid, data}` / `{:EXIT, ...}` message protocol throughout. Every user service is started via erlexec to get OS-level process-group kill semantics — services often run through `bash -c` / `npx` wrappers and Bates needs to terminate the full subtree, not just the shell. `Port.open` doesn't give us that. erlexec is core, not a Caddy convenience.

**Why we can't keep using only an escript.** The escript model fundamentally can't carry priv-dir native binaries. There's no flag, no mode, no workaround that fixes this — it's a property of the format. Any path forward involves a different packaging model for the daemon.

## What This Unlocks

1. **The daemon actually works** as a built artifact, not just under `mix phx.server`.
2. **A real distribution story.** Mix releases produce `batesd` as a self-contained tree (`bin/batesd`, `releases/`, `lib/`, ERTS). A future Homebrew formula can install it without depending on the user having Erlang for the daemon side.
3. **No lock-in to a third-party tool.** `mix release` is core OTP. No Burrito, no Bakeware, no Zig.
4. **The escript stays fast.** `bates env myapp` keeps its ~200ms cold-start. `eval "$(bates env myapp)"` in a `.envrc` is still cheap.
5. **Clear separation of concerns.** Control commands speak HTTP; the daemon owns OTP boot. The broken layering that POC #2 exposed — an escript trying to start the OTP tree — goes away because there is no `bates start` anymore.

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted or executed.

**Build configuration:**

- `source/mix.exs:12` — current `escript:` config (`main_module: Bates.CLI, name: "bates", app: nil`). Stays.
- `source/mix.exs:17-22` — `application/0` already declares `mod: {Bates.Application, []}`. Reused by the release.
- `source/mix.exs:28-41` — `deps/0`. erlexec is `{:erlexec, "~> 2.3"}`. Stays.

**Code that must come out (merged in PR #31):**

- `source/lib/bates/cli/start.ex` — the broken `Bates.CLI.Start.run/1` module. Delete.
- `source/lib/bates/cli.ex` — the `start` clause of `dispatch/1` and the `start` line in `usage/0`. Remove.
- `source/test/bates/cli/start_test.exs` — argv parsing tests for the doomed module. Delete.
- `specs/cli.md` — the `### \`bates start\`` section. Remove.

**Daemon supervision tree (no changes — runs the same way under the release):**

- `source/lib/bates/application.ex` — `Registry` → `Phoenix.PubSub` → `Bates.ProcessSupervisor` → `BatesWeb.Endpoint` → `Bates.Caddy`.
- `source/lib/bates/app.ex` — owns service-process lifecycle via `:exec.run_link/2` (line 345), `:exec.stop/1` (line 182), `:exec.kill/2` (line 394).
- `source/lib/bates/caddy.ex` — owns the Caddy reverse-proxy process via `:exec.run_link/2`.
- `source/lib/bates/config.ex` — already reads its path from `Application.get_env(:bates, :config_path, ...)`. The release inherits this.

**Reusable from PR #31:**

- `source/lib/bates/prerequisites.ex` — `Bates.Prerequisites.verify/0`. Now invoked from `Bates.Application.start/2` instead of the escript.
- `source/lib/bates/cli/client.ex`, `source/lib/bates/cli/{up,down,restart,status,env,setup}.ex` — untouched. The control commands are correct.

**Existing architectural references:**

- `specs/cli.md` — the contract for the six remaining control subcommands. Stays mostly intact.
- `specs/system-overview.md` — needs a paragraph on the two-binary topology and the fact that `batesd` is the entry point for the server.
- `README.md` — install/run instructions get a section on building and running `batesd`.

---

## Proposed Design

### Two binaries

| Binary    | Built by                          | Contains                            | Purpose                              |
|-----------|-----------------------------------|-------------------------------------|--------------------------------------|
| `bates`   | `mix escript.build`               | `.beam` archive only                | Control commands. Fast cold-start.   |
| `batesd`  | `MIX_ENV=prod mix release batesd` | ERTS, all `.beam`, all `priv/` dirs | The daemon. Boots the OTP tree.      |

Both binaries share the same source tree and the same `Bates.*` modules. The split is purely a packaging boundary.

### How users start the server

Users run `batesd` directly:

```
$ batesd
$ batesd --config /path/to/config.toml
```

`batesd` is a foreground process. Logs stream to stdout. Ctrl-C shuts it down cleanly. No subcommand — the bare command name is the verb.

There is no `bates start` wrapper. The `bates` escript no longer attempts to boot the OTP tree under any code path; it only speaks HTTP.

A future proposal will add `bates setup`-managed launchd integration so `batesd` is supervised by the system in normal use. Until then, users invoke it manually (typically via a terminal window or a tmux pane).

### `batesd` flags

| Flag              | Default                            | Behavior |
|-------------------|------------------------------------|----------|
| `--config <path>` | `~/.config/bates/config.toml`      | Path to the configuration file. |

Same default and parsing semantics as the doomed `bates start` had. Argv is parsed in the application start callback (see *Entry point* below) before the supervision tree boots.

No `--no-prereq-check`, no `--port`, no `--detach`, no `--log-level`. Keep the surface minimal until a real caller asks for more.

### Entry point

Boot sequence inside `Bates.Application.start/2`:

1. Parse `System.argv()` for `--config <path>` (default `~/.config/bates/config.toml`). Set `:bates, :config_path` via `Application.put_env/3`.
2. Run `Bates.Prerequisites.verify/0`. On failure, write the existing diagnostic to stderr and exit non-zero. Same error messages as PR #31's escript path.
3. Build and return the supervision spec. Caddy and the Endpoint bind their ports here; if 443 is already taken (another `batesd` running, another web server, etc.), Bandit's `:eaddrinuse` propagates as a startup failure with a clear message. We rely on this rather than a separate "already running" probe — the OS error is authoritative.

This logic runs identically under `mix phx.server` (which calls `start/2`) and under `bin/batesd` (the release launcher). Test runs are unaffected because `mix test` doesn't invoke `start/2`.

### Release configuration

A new `releases:` keyword in `source/mix.exs`:

```elixir
def project do
  [
    # ... existing keys ...
    escript: [main_module: Bates.CLI, name: "bates", app: nil],
    releases: [
      batesd: [
        version: "0.1.0",
        applications: [bates: :permanent],
        include_executables_for: [:unix],
        steps: [:assemble]
      ]
    ]
  ]
end
```

No `rel/env.sh.eex` or `rel/vm.args.eex` templates — defaults are fine.

### Overlay to make `batesd` the command

`mix release` generates `bin/batesd` as a multi-subcommand launcher (`batesd start`, `batesd daemon`, `batesd remote`, etc.). We don't want subcommands.

A release overlay at `source/rel/overlays/bin/batesd` overrides the generated launcher with a thin script that always runs the foreground start path:

```sh
#!/bin/sh
# Override of mix release's generated bin/batesd launcher.
# We expose a single foreground command, not a subcommand dispatcher.
exec "$(dirname "$0")/batesd-release" start "$@"
```

(`batesd-release` is the renamed mix-generated launcher, achieved via a build-time `cp`/`mv` step or a custom `:steps` callback. Exact mechanics get nailed down in the plan.)

The user-facing surface is `batesd [--config <path>]`. The mix-release start subcommand is an implementation detail.

### What stays the same

- All six remaining control subcommands' user-facing contracts (output, exit codes, eval-safety of `bates env`).
- The `specs/cli.md` contract for those six.
- The JSON API surface.
- The supervision tree.
- erlexec usage in `Bates.App` and `Bates.Caddy`.
- `Bates.Prerequisites`, `Bates.CLI.Client`, the `:bates, :config_path` plumbing.

### What changes

**Removals (cleanup of merged PR #31):**

- Delete `source/lib/bates/cli/start.ex`.
- Delete `source/test/bates/cli/start_test.exs`.
- Remove the `start` clause from `Bates.CLI.dispatch/1` in `source/lib/bates/cli.ex`.
- Remove the `start` line from `Bates.CLI.usage/0` in `source/lib/bates/cli.ex`.
- Remove the `### \`bates start\`` section from `specs/cli.md`.

**Additions:**

- `source/mix.exs` — add `releases:` keyword.
- `source/rel/overlays/bin/batesd` — overlay script that exposes `batesd` as the foreground command.
- `source/lib/bates/application.ex` — argv parsing + prereq check at the top of `start/2`.
- `source/lib/bates/daemon.ex` (or similar) — small module owning argv parsing if `Bates.Application.start/2` becomes too large. Optional.
- `source/test/bates/daemon_test.exs` — unit tests for `--config` parsing (including the default) and prereq exit paths.

**Spec / doc updates:**

- `specs/system-overview.md` — add a paragraph on the two-binary topology and that `batesd` is the server entry point.
- `specs/cli.md` — remove `bates start`. Possibly add a short note pointing at `batesd` as the way to start the server.
- New `specs/batesd.md` (or section in `specs/system-overview.md`) — document `batesd` flags, prereq behavior, log streaming, signal handling.
- `README.md` — replace `mix phx.server` with the dual-binary build steps (`mix escript.build` + `mix release batesd`) and the run instructions for `batesd`.
- `.gitignore` — add `_build/prod/rel/` if not already covered.

---

## Scope

- **Cleanup:** delete the merged `Bates.CLI.Start` module, its dispatcher clause, its test file, its spec section, and its usage line.
- **Build:** add `releases:` config to `source/mix.exs`; add `rel/overlays/bin/batesd`; document `mix release batesd` in the README.
- **Daemon:** move prereq check + argv parsing into `Bates.Application.start/2` (or a small `Bates.Daemon` helper called from `start/2`).
- **Tests:** add `daemon_test.exs` covering argv parsing and prereq exit paths.
- **Specs:** update `specs/cli.md` (remove `bates start`), update `specs/system-overview.md` (two-binary topology), add `batesd` documentation.
- **Docs:** `README.md` install/build/run section.
- **Out of scope:** Homebrew formula (separate follow-up proposal once `mix release` artifacts exist), launchd integration (separate v2 proposal), Linux support, Windows support, signed/notarized binaries.

---

## Design Principles

- **Don't break what works.** PR #31's other commits — `Bates.CLI.Client`, `Bates.Prerequisites`, the app-env config plumbing, the dispatcher consolidation, the six working subcommands — stay. This proposal removes only the broken `bates start` artifacts and adds the daemon binary.
- **No new third-party packaging deps.** Plain `mix release`. No Burrito, no Bakeware, no Zig.
- **One verb per binary.** `bates` is for control. `batesd` is for the server. No subcommand maze on either.
- **The OS is authoritative.** Rely on port-bind failure for "already running" detection rather than an HTTP self-probe. Fewer round-trips, no false positives, no race window.
- **Prereqs gate the daemon, not the control commands.** The control commands assume the daemon is up; if it isn't, they emit their own "Bates is not running" message. The daemon owns the system-prereq check because the daemon is what actually requires `caddy` and the resolver file.
- **Treat the CLI ↔ JSON API boundary as portable.** The `bates` escript is a candidate for a future rewrite in a non-BEAM language (Go, Rust) to remove the system Erlang dependency. Implementation work in this proposal — and follow-on CLI work — should respect that boundary: keep control commands as thin HTTP clients; don't push daemon-side logic into CLI modules; don't introduce BEAM-specific runtime requirements in control commands. `bates setup` may shell out (`sudo`, `caddy trust`). Anything that requires Elixir/OTP belongs in `batesd`.

---

## Decided

Captured during the 2026-05-03 refinement pass:

1. **launchd integration** — defer to a v2 proposal. This proposal ships direct `batesd` invocation only.
2. **PR #31 cleanup** — already merged. This proposal's execution removes the broken `bates start` artifacts from master.
3. **`batesd` flags** — `--config <path>` only, default `~/.config/bates/config.toml`. No `--no-prereq-check` or other flags in v1.
4. **Already-running probe** — dropped. `batesd` fails naturally on port-bind conflict; the OS error is authoritative.
5. **Prereq check** — lives in `batesd` startup (top of `Bates.Application.start/2`), before the supervision tree boots.
6. **Homebrew packaging** — out of scope. Follow-up proposal once `mix release` artifacts exist.
7. **Release configuration** — defined inline in `source/mix.exs`'s `releases:` keyword. No `rel/env.sh.eex` or `rel/vm.args.eex` templates for v1.
8. **Entry point** — `Bates.Application.start/2` reads `System.argv()` for `--config` and runs the prereq check. A release overlay at `source/rel/overlays/bin/batesd` overrides the generated launcher so the user-facing command is `batesd` (no subcommand).
9. **Logging** — unchanged from `bates start`. Foreground BEAM, Logger to stdout, Ctrl-C shuts down.
10. **Tests** — delete merged `start_test.exs`. Add `daemon_test.exs` covering argv parsing and prereq exit paths. Release boot itself is manual smoke-test territory (acceptance criterion in the plan).

---

## Open Questions

1. **Where does argv parsing live — directly in `Bates.Application.start/2` or in a dedicated `Bates.Daemon` module called from `start/2`?** Either works. A separate module is cleaner if argv parsing grows beyond `--config`. Recommend deciding during plan creation based on how big the parser turns out to be.

2. **Overlay mechanics for renaming the generated `bin/batesd`.** The overlay needs to either (a) rename the mix-generated launcher to `batesd-release` via a custom `:steps` callback before the overlay drops in, or (b) put the overlay at a different path and have the overlay invoke the original via its known relative location. Defer the exact mechanism to plan-creation time — this is a small implementation detail, not an architectural decision.

3. **Does `mix test` need any changes?** Tests today don't call `start/2`. Adding argv parsing + prereq check to `start/2` shouldn't affect tests, but worth verifying during plan execution. If a test path does call `start/2` (e.g. integration tests via `Application.ensure_all_started`), the prereq check needs to be skippable in `:test` env — likely via an internal `if Mix.env() == :test` guard, but confirm before writing it that way.

---

## Risks and Mitigations

- **Release size:** ~30-40MB including ERTS. Fine for a local dev tool. Worth noting in the README.
- **Two-step build:** `mix escript.build` and `mix release batesd` are separate commands. README must document both. Consider a `mix bates.build` task that runs both in sequence as a quality-of-life follow-up.
- **Users running multiple `batesd` instances by accident:** mitigated by the port-bind failure; second instance exits with a clear error from Bandit. Pretty close to a no-op risk in practice.
- **Removing `bates start` from a recently merged PR:** small churn cost. The alternative (keep a broken command around indefinitely) is worse. The plan should land on master with a clear "supersedes the `bates start` portion of PR #31" note in the commit message.
