# Mix Release for the Daemon — Proposal

**Status:** Draft
**Date:** 2026-05-02
**Author:** Tyler + Claude
**Origin:** Hand-test of `bates start` (PR [#31](https://github.com/tylerhunt/bates/pull/31)) failed with an `erlexec` priv-dir lookup error. Follow-up to the accepted [Add CLI Commands proposal](accepted/2026-05-01-add-cli-commands.md).

## Summary

Split the `bates` binary in two. Keep `bates` as an escript for the control commands (`env`, `status`, `up`, `down`, `restart`, `setup`) — they need fast cold-start and only speak HTTP to a running daemon. Ship the daemon (`bates start`) as a Mix release named `batesd`, which embeds ERTS and includes priv directories, so `erlexec` can find its `exec-port` C binary at runtime.

`bates start` keeps its current user-facing contract — it's still `bates start [--config <path>]` — but its implementation becomes a thin `:os.execvp` into the `batesd` release binary that lives next to it on disk.

## Problem

The just-shipped `bates start` command (PR #31, Phase 4 of the Add-CLI-Commands plan) does not work outside of `mix phx.server`. Hand-testing the built escript exposes the failure:

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

1. **`bates start` actually works** as a built binary, not just under `mix phx.server`.
2. **A real distribution story.** Mix releases produce `batesd` as a self-contained tree (`bin/batesd`, `releases/`, `lib/`, ERTS) that a Homebrew formula can install to `Cellar/bates/<vsn>/` directly.
3. **No lock-in to a third-party tool.** `mix release` is core OTP. No Burrito, no Bakeware, no Zig. We can revisit those later if we want single-file distribution.
4. **The escript stays fast.** `bates env myapp` keeps its ~200ms cold-start. `eval "$(bates env myapp)"` in a `.envrc` is still cheap.
5. **Clear separation of concerns.** Control commands speak HTTP; the daemon owns OTP boot. The broken layering that POC #2 exposed (escript trying to start the OTP tree) goes away.

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted or executed.

**Build configuration:**

- `source/mix.exs:12` — current `escript:` config (`main_module: Bates.CLI, name: "bates", app: nil`). Stays.
- `source/mix.exs:17-22` — `application/0` already declares `mod: {Bates.Application, []}`. Reused by the release.
- `source/mix.exs:28-41` — `deps/0`. erlexec is `{:erlexec, "~> 2.3"}`. Stays.

**The daemon entrypoint that's currently broken:**

- `source/lib/bates/cli/start.ex:1-85` — the new `Bates.CLI.Start.run/1` shipped in PR #31. Currently:
  1. Parses `--config` with `OptionParser`.
  2. Verifies prerequisites (`Bates.Prerequisites.verify/0`).
  3. Probes `/status` via `Bates.CLI.Client.get/2`.
  4. Calls `Application.ensure_all_started(:bates)` — **fails here** because erlexec can't start.
  5. `Process.sleep(:infinity)`.
  This module will be rewritten as a thin shim that exec's the release.

**Daemon supervision tree (no changes — runs the same way under the release):**

- `source/lib/bates/application.ex` — `Registry` → `Phoenix.PubSub` → `Bates.ProcessSupervisor` → `BatesWeb.Endpoint` → `Bates.Caddy`.
- `source/lib/bates/app.ex` — owns service-process lifecycle via `:exec.run_link/2` (line 345), `:exec.stop/1` (line 182), `:exec.kill/2` (line 394).
- `source/lib/bates/caddy.ex` — owns the Caddy reverse-proxy process via `:exec.run_link/2`.
- `source/lib/bates/config.ex` — already reads its path from `Application.get_env(:bates, :config_path, ...)`. The release inherits this.

**Dispatcher and tests already in place:**

- `source/lib/bates/cli.ex` — escript dispatcher with clauses for all seven subcommands. The `start` clause stays; only `Bates.CLI.Start`'s body changes.
- `source/test/bates/cli/start_test.exs` — argv parsing tests. Stays. The `Application.ensure_all_started/1` happy path was already documented as out-of-scope for unit tests.

**Existing architectural references:**

- `specs/cli.md` — the contract for all subcommands. Mostly unchanged; `bates start` keeps its public surface.
- `specs/system-overview.md` — needs a paragraph on the two-binary topology.
- `README.md` — install instructions are currently "clone the repo, run `mix phx.server`." Will need a Homebrew section.

---

## Proposed Design

### Two binaries

| Binary    | Built by              | Contains                          | Purpose                              |
|-----------|----------------------|-----------------------------------|--------------------------------------|
| `bates`   | `mix escript.build`   | `.beam` archive only              | Control commands. Fast cold-start.   |
| `batesd`  | `MIX_ENV=prod mix release batesd` | ERTS, all `.beam`, all `priv/` dirs | The daemon. Boots the OTP tree.      |

Both binaries share the same source tree and the same `Bates.*` modules. The split is purely a packaging boundary.

### How `bates start` works

`Bates.CLI.Start.run/1` becomes a shim:

1. Parse argv as today (keep `--config <path>` validation).
2. Verify prerequisites (`Bates.Prerequisites.verify/0`) — escript-side, fast, no OTP needed.
3. Probe `/status` (already-running check) — escript-side, fast.
4. Locate `batesd` on disk (see *Discovery* below).
5. `:os.execvp("batesd", forwarded_argv)` — the escript process is replaced by the release process; signal handling, stdout/stderr, and the controlling TTY pass through unchanged.

Steps 2 and 3 staying in the escript means **fast failure**: missing `caddy` or an already-running daemon doesn't pay the ERTS-startup tax (~500-1000ms). It also means the user-facing error messages and exit codes (defined in PR #31's acceptance criteria) don't move.

Step 5's `execvp` is the simplest hand-off semantics: from the user's perspective `bates start` *is* the daemon process. Ctrl-C goes to ERTS, not the escript. There's no "escript watching a release" problem.

### `batesd` discovery

The escript needs to find the release binary. Three lookup strategies, tried in order:

1. **`BATES_DAEMON` env var** if set — explicit override for development and packagers.
2. **Sibling lookup:** if the escript is at `<prefix>/bin/bates`, try `<prefix>/bin/batesd`. This is what Homebrew gives us (`/opt/homebrew/bin/bates` → `/opt/homebrew/bin/batesd`).
3. **`$PATH` lookup** as the final fallback. If `batesd` is on the path, use it.

If none of these resolve, print a diagnostic to stderr explaining that the daemon binary couldn't be found and exit 2.

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
        steps: [:assemble, :tar]
      ]
    ]
  ]
end
```

This produces:

- `source/_build/prod/rel/batesd/` — the release tree.
- `source/_build/prod/rel/batesd/bin/batesd` — the launcher script.
- `source/_build/prod/batesd-0.1.0.tar.gz` — packageable artifact.

The release boots `Bates.Application` — same supervision tree as today. No code changes to the supervision tree, `Bates.App`, `Bates.Caddy`, or anything downstream.

### Build, install, and run

**Local development (now):**

```bash
cd source
mix deps.get
mix escript.build              # produces source/bates
MIX_ENV=prod mix release batesd  # produces source/_build/prod/rel/batesd/bin/batesd
```

For development, set `BATES_DAEMON=$(pwd)/_build/prod/rel/batesd/bin/batesd` so the escript can find the release. (Or symlink both binaries into a directory on `$PATH` — see the Homebrew layout below.)

**Distribution (eventually):**

A Homebrew formula installs both binaries side by side under one prefix:

```
/opt/homebrew/Cellar/bates/0.1.0/
  bin/
    bates          # escript — symlinked to /opt/homebrew/bin/bates
    batesd         # release launcher — symlinked to /opt/homebrew/bin/batesd
  libexec/
    batesd/        # release tree (releases/, lib/, erts-*/)
```

The formula is out of scope for this proposal — it lives in a separate `homebrew-bates` tap. But the on-disk layout above is what this work needs to enable.

### What stays the same

- All seven subcommands' user-facing contracts (output, exit codes, eval-safety of `bates env`).
- The `specs/cli.md` contract.
- The JSON API surface.
- The supervision tree.
- erlexec usage in `Bates.App` and `Bates.Caddy`.
- `Bates.Prerequisites`, `Bates.CLI.Client`, the `:bates, :config_path` plumbing — all still load from the escript and the release.

### What changes

- `source/mix.exs` — add `releases:` keyword.
- `source/lib/bates/cli/start.ex` — rewrite from "boot OTP" to "exec batesd".
- `source/test/bates/cli/start_test.exs` — drop the boot-path tests, add tests for `batesd` discovery (env var, sibling, PATH, missing).
- `specs/cli.md` — note that `bates start` execs the daemon binary; document the discovery order and `BATES_DAEMON` override.
- `specs/system-overview.md` — add a brief two-binary topology paragraph.
- `README.md` — replace "run `mix phx.server`" with the dual-binary build steps until the Homebrew formula lands.
- New `.gitignore` entries for `_build/prod/rel/` if not already covered.

---

## Scope

- **Build:** add `releases:` config; document `mix release batesd` in the README; ensure CI builds both binaries.
- **CLI:** rewrite `Bates.CLI.Start.run/1` as a discovery + `execvp` shim. Keep argv parsing, prereq check, and already-running probe escript-side.
- **Tests:** unit tests for the discovery order; remove the now-irrelevant "ensure_all_started" path comments.
- **Specs:** `specs/cli.md` and `specs/system-overview.md` updates.
- **Docs:** `README.md` install/build section.
- **Out of scope:** the Homebrew formula itself (separate repo / future PR), Linux support, Windows support, signed/notarized binaries.

---

## Design Principles

- **Don't break what just shipped.** PR #31's nine refactor commits stay. The shared `Bates.CLI.Client`, `Bates.Prerequisites`, app-env config path, dispatcher updates, and `specs/cli.md` reconciliation are correct and reused. This proposal changes only the *packaging* of `bates start`.
- **No new third-party packaging deps.** Plain `mix release`. No Burrito, no Bakeware, no Zig. `mix release` is core OTP and well-trodden.
- **Two binaries, one user model.** Users still type `bates start`. The fact that it execs into `batesd` is an implementation detail, surfaced in the spec and in error messages but not in normal flow.
- **Fail fast in the escript.** Cheap checks (prereqs, already-running) stay escript-side. ERTS startup only happens on the success path.
- **Discoverability over magic.** `BATES_DAEMON` env var first, then sibling, then `$PATH`. Each step is explainable in a short error message when discovery fails.
- **Treat the CLI ↔ JSON API boundary as portable.** The `bates` escript is a candidate for a future rewrite in a non-BEAM language (Go, Rust) to remove the system Erlang dependency and enable single-binary `curl | sh` distribution. Implementation work in this proposal — and follow-on CLI work — should respect that boundary: keep control commands as thin HTTP clients; don't push daemon-side logic into CLI modules; don't introduce BEAM-specific runtime requirements in control commands. `bates setup` may shell out (`sudo`, `caddy trust`), and `bates start`'s `:os.execvp` shim is portable to `syscall.Exec` in any language. Anything that requires Elixir/OTP belongs in `batesd`.

---

## Open Questions

1. **`mix release` env vs. `MIX_ENV=prod`.** The release should be built with `MIX_ENV=prod` for compile-time pruning of test code. This is the standard practice but worth being explicit about in the README and CI.

2. **`batesd` vs `bates-daemon` vs `bates-server`.** `batesd` is the BSD-style convention (`sshd`, `httpd`, `caddy`). It's short and idiomatic for a long-running process. The alternative — making `batesd` an internal-only binary the user never types directly — is also valid but more magical.

3. **Homebrew layout: `bin/batesd` exposed or hidden?** Two choices:
   - **Exposed** (`bin/batesd` symlinked to `$PATH`): users could run `batesd --config ...` directly, bypassing the escript. Documented as an advanced path. Simpler install.
   - **Hidden** (`libexec/batesd/bin/batesd`): only `bates` is on `$PATH`. The escript discovers the release via a known relative path. Cleaner but requires a more elaborate install layout and one extra hop in `:os.execvp`.

   Recommend **exposed** for v1 — fewer moving parts, advanced users can use it directly, the escript still works.

4. **Argv pass-through to `batesd`.** `bates start --config /path/to/foo.toml` becomes `:os.execvp("batesd", ["start", "--config", "/path/to/foo.toml"])` — but the release's CLI doesn't have a `start` subcommand of its own. Two paths:
   - The release uses `mix release`'s default startup (`bin/batesd start` is the launcher convention) and `--config` is parsed inside `Bates.Application.start/2` via OS env (`BATES_CONFIG_PATH`).
   - The release wraps a custom Elixir entry that re-parses argv.

   Recommend the env-var path: simpler, matches release conventions, and the `Application.put_env(:bates, :config_path, ...)` call moves to `Bates.Application.start/2` reading from `System.get_env("BATES_CONFIG_PATH")`. The escript sets the env var before exec'ing.

5. **Versioning the release.** Today `mix.exs` has `version: "0.1.0"`. The release should pin to the same version. When we cut releases, we bump `mix.exs` and rebuild both binaries. No independent versioning between escript and release — they're tested as a pair.

6. **Test environment.** The release should not be built or required during `mix test`. Tests run against the source tree as today. The release is a packaging concern, not a test concern.

7. **Should `bates start` still print "Bates is already running" / prereq diagnostics from the escript, or should they move into the release?** Recommend escript: failing fast without ERTS startup is a real UX win, and these checks are pure data (HTTP probe + file/path checks). They don't need OTP.

---

## Risks and Mitigations

- **`:os.execvp` semantics on macOS:** confirmed it's a standard POSIX call; signals, stdout/stderr, controlling TTY all hand off correctly. Verify in Phase 1 hand-test.
- **Release size:** ~30-40MB including ERTS. For a local dev tool this is fine. Worth noting in the README.
- **"Two binaries" install confusion:** mitigated by Homebrew (one `brew install bates` installs both). For the source-build path, the README documents the two `mix` commands.
- **Stale `batesd` after `bates` upgrade:** if a user has both binaries on disk but the escript is newer than the release, behavior is undefined. Mitigation: the escript and release are versioned together (same `mix.exs` version field) and the Homebrew formula upgrades them atomically.