# Plan: Mix Release for the Daemon

**Proposal:** [Mix Release for the Daemon](../proposals/accepted/2026-05-03-mix-release-for-daemon.md)

### Revision Log

| Date | What Changed |
|------|-------------|
| 2026-05-03 00:30 PDT | Plan created. Seven phases covering removal of broken `bates start`, daemon boot in `Application.start/2`, `mix release` config + overlay, specs, README, manual smoke test. |
| 2026-05-03 01:15 PDT | Readiness audit applied. Phase 3 locks in `Application.get_env(:bates, :skip_prereq_check, false)` gating (Mix is not available at release runtime); adds `source/config/test.exs` change to Files. Phase 4 adds note that `config/runtime.exs` is not expected to be needed and clarifies overlay-mechanic fallback. Acceptance criteria gain a `skip_prereq_check` config item. |

## Goal

Ship the Bates daemon as a Mix release named `batesd`, remove the broken `bates start` subcommand merged in PR #31, and move prerequisite + argv handling into `Bates.Application.start/2` so the same supervision tree boots correctly under `bin/batesd`.

## Why This Matters

The merged `bates start` command crashes immediately on a built escript because escripts can't carry `erlexec`'s `priv/exec-port` C binary. The escript packaging format is the wrong tool for the daemon. A Mix release embeds ERTS and includes priv directories, so erlexec finds its binary at runtime. The `bates` escript stays around for the six fast-cold-start control commands (`env`, `status`, `up`, `down`, `restart`, `setup`).

Users will invoke `batesd` directly to start the server. A future proposal will add launchd integration via `bates setup`.

## Acceptance Criteria

- [x] `Bates.CLI.Start` module deleted.
- [x] `start` clause removed from `Bates.CLI.dispatch/1`; `bates start` no longer appears in `Bates.CLI.usage/0` output.
- [x] `source/test/bates/cli/start_test.exs` deleted.
- [x] `Bates.CLITest`'s usage assertions updated — no assertion on `"bates start"` remaining.
- [x] `Bates.CLI.Client.not_running_message/0` points users at `batesd`, not `bates start`. Tests updated to match.
- [x] `Bates.Prerequisites` and `Bates.CLI.Setup` docstrings no longer reference `bates start`.
- [x] `source/mix.exs` declares a `releases:` keyword with a `batesd` release.
- [x] `MIX_ENV=prod mix release batesd` succeeds and produces `source/_build/prod/rel/batesd/bin/batesd`.
- [x] `Bates.Application.start/2` parses `System.argv()` for `--config <path>`, runs `Bates.Prerequisites.verify/0`, and emits the same diagnostic + non-zero exit on failure that `bates start` did.
- [x] `source/config/test.exs` sets `config :bates, skip_prereq_check: true` so the prereq gate doesn't fire during `mix test`.
- [x] No `Mix.*` call appears in `Bates.Application.start/2` or any module reachable from it. (`Mix` is build-time only and unavailable in releases.)
- [x] An overlay at `source/rel/overlays/bin/batesd` makes `bin/batesd` (no subcommand) the foreground command. `bin/batesd --config /path/to/foo.toml` boots the supervision tree.
- [x] `source/test/bates/daemon_test.exs` covers `--config` parsing (default + override) and the prereq exit path.
- [x] `mix test` passes.
- [x] `mix format --check-formatted` passes.
- [x] `specs/cli.md`'s `### bates start` section removed; remaining `bates start` references updated to point at `batesd`.
- [x] `specs/system-overview.md` mentions the two-binary topology and that `batesd` is the server entry point.
- [x] `README.md` documents `mix release batesd` and how to run `batesd`.
- [ ] Manual smoke test: `_build/prod/rel/batesd/bin/batesd` boots, serves the dashboard at `https://bates.test`, Ctrl-C shuts it down. `bates status`, `bates up <name>`, and `bates env <name>` all work against the running daemon. (User to verify before merge.)

## Phases

### Phase 1 — Remove the broken `bates start` artifacts

Delete the doomed module, the dispatcher clause, the usage line, the test file, and the spec section. After this phase the escript no longer claims to start the server.

**Files:**

- `source/lib/bates/cli/start.ex` — delete the file.
- `source/test/bates/cli/start_test.exs` — delete the file.
- `source/lib/bates/cli.ex`:
  - Remove the `def dispatch(["start" | rest]), do: Bates.CLI.Start.run(rest)` line.
  - Remove the `bates start [--config <path>]` line from `usage/0`.
- `source/test/bates/cli_test.exs`:
  - Remove the `assert output =~ "bates start"` line in the `no arguments writes multi-line usage` test.

**Tests:** `mix test` should pass after this phase. The dispatcher no longer routes `["start" | _]` so unknown subcommands fall through to `usage/0` (already covered by an existing test).

### Phase 2 — Update "not running" messaging

The control commands currently tell users to run `bates start` when the daemon is unreachable. Update to point at `batesd`.

**Files:**

- `source/lib/bates/cli/client.ex`:
  - Change `not_running_message/0` to return `"Bates is not running. Start it with: batesd"`.
- `source/test/bates/cli/client_test.exs`:
  - Update both `transport_message/1` assertions (lines around 86 and 93) to match the new string.
- `source/lib/bates/prerequisites.ex`:
  - Update the module `@moduledoc` and `verify/0` docstring to reference `batesd` instead of `bates start`. Reword to "System prerequisite checks gating `batesd` startup."
- `source/lib/bates/cli/setup.ex`:
  - Update the `@moduledoc` to read "One-time system setup for `batesd`."

**Tests:** `mix test` passes.

### Phase 3 — Move daemon boot logic into `Bates.Application`

Move argv parsing and prereq verification into `Bates.Application.start/2`. Reuse `Bates.Prerequisites.verify/0` and the same error formatting `Bates.CLI.Start` used.

**Files:**

- `source/lib/bates/application.ex`:
  - At the top of `start/2`, before building the supervision spec:
    1. Parse `System.argv()` with `OptionParser.parse(argv, strict: [config: :string])`. On unknown flags or unexpected positional args, write a `Usage: batesd [--config <path>]` message to stderr and `System.halt(2)`.
    2. If `--config <path>` parsed, `Application.put_env(:bates, :config_path, Path.expand(path))`.
    3. If `Application.get_env(:bates, :skip_prereq_check, false)` is `true`, skip the prereq check. (Set to `true` only in the test environment — see `source/config/test.exs` below.)
    4. Otherwise run `Bates.Prerequisites.verify/0`. On `{:error, reason}`, write the same diagnostic `Bates.CLI.Start` emitted (`bates: prerequisite not met: <reason>\nRun \`bates setup\` to configure system prerequisites.\n`) to stderr and `System.halt(2)`.
  - Build and return the supervision spec exactly as today (`{:ok, _} = Supervisor.start_link(children(), opts)`).
- `source/config/test.exs`:
  - Add `config :bates, skip_prereq_check: true` so `mix test` doesn't trip the prereq gate (CI / dev machines may not have `caddy` on `$PATH` or `/etc/resolver/test`).

**Notes:**

- **Do not call `Mix.env/0` (or any `Mix.*` function) from `Bates.Application.start/2` or anything reachable from it.** `Mix` is a build-time module and is not packaged into a `mix release`. Calling it at daemon boot raises `UndefinedFunctionError` and crashes the supervision tree before it starts. Use `Application.get_env(:bates, :skip_prereq_check, false)` instead — `false` is the safe default for the prod release; `config/test.exs` flips it to `true` for the test environment.
- A new module — `Bates.Daemon` — is acceptable if `start/2` becomes too large. Keep it under `source/lib/bates/daemon.ex` with a single `parse_argv/1` (pure: returns `{:ok, opts}` or `{:error, message}`) and `verify_prerequisites/0` API. If three or fewer lines of orchestration remain in `start/2`, leave it inline.
- Structure `parse_argv/1` as a pure function so the test doesn't need to capture `System.halt`. The thin `start/2` wrapper handles the halt-on-error case.

**Tests:**

- New file `source/test/bates/daemon_test.exs`:
  - `--config /path/to/foo.toml` sets `:bates, :config_path` to the expanded path.
  - No `--config` leaves `:bates, :config_path` unset (so `Bates.Config.path/0` falls through to its default).
  - Unknown switch (e.g., `--bogus`) writes a `batesd` usage line to stderr and returns/halts with 2. Use `capture_io(:stderr, fn -> ... end)` and structure the parser as a pure function (`Bates.Daemon.parse_argv/1` returning `{:ok, opts}` or `{:error, message}`) so the test doesn't need to capture `System.halt`.
  - Prereq verification path: stub or temporarily clobber `$PATH` to make `caddy` lookup fail; assert the error-formatting helper emits the expected diagnostic. Mirror `start_test.exs`'s "prerequisite gating" test.

### Phase 4 — Add the `mix release` configuration

Wire the release into `mix.exs` and add the overlay that exposes `batesd` (no subcommand) as the user-facing command.

**Files:**

- `source/mix.exs`:
  - In `project/0`, add the `releases:` keyword:
    ```elixir
    releases: [
      batesd: [
        version: "0.1.0",
        applications: [bates: :permanent],
        include_executables_for: [:unix],
        steps: [:assemble]
      ]
    ]
    ```
- `source/rel/overlays/bin/batesd` — new file. Override the generated launcher so the user-facing command is `batesd` (no subcommand). Two acceptable mechanics:
  1. Drop a script named `batesd` that execs the original launcher with `start` prepended: `exec "$(dirname "$0")/batesd-orig" start "$@"`. Requires renaming the generated launcher in a custom `:steps` callback.
  2. Drop a script named `batesd` (overwriting the generated one) that locates and exec's the underlying `erts-*/bin/erl` directly using the same env the generated launcher would have set. More fragile across mix-release versions.

  Prefer (1). Implement the rename via a custom step in the `releases:` config:
  ```elixir
  steps: [:assemble, &rename_launcher/1]
  ```
  where `rename_launcher/1` is a private function in `mix.exs` that does `File.rename!(Path.join(release.path, "bin/batesd"), Path.join(release.path, "bin/batesd-orig"))` and returns the release. The overlay then drops `bin/batesd` after `:assemble` runs.

  If the overlay/`:steps` ordering turns out to be awkward, fall back to a custom step that writes the wrapper script directly without using the overlay mechanism. Document the chosen mechanism in a short comment in `mix.exs`.

  **How to verify it took:** after `mix release batesd`, run `_build/prod/rel/batesd/bin/batesd --help`. If the output is mix-release subcommand help (lists `start`, `daemon`, `remote`, `eval`, `rpc`, `restart`, `stop`, `pid`, `version`), the overlay didn't take. The expected behavior for the new launcher is either to boot the daemon (because `--help` was passed as an argv to be parsed by `Bates.Application.start/2`) or to fail with our own usage message — *not* to print the mix-release subcommand list.

- Verify `source/.gitignore` already covers `/_build/` (it does) — no change needed.

- **`config/runtime.exs` is not expected to be needed.** The release reads its only environment-dependent setting (`--config <path>`) from argv, not from runtime config. Don't add `runtime.exs` preemptively. If the release fails to boot for a runtime-config reason during the smoke test, add a minimal stub at that point.

**Tests:**

- `MIX_ENV=prod mix release batesd` from `source/` exits 0 and produces `_build/prod/rel/batesd/bin/batesd`.
- `_build/prod/rel/batesd/bin/batesd --help` does NOT print mix-release subcommand help. (If it does, the overlay didn't take.)
- Smoke test in Phase 7 covers the actual boot.

### Phase 5 — Update specs

`specs/` is the source of truth and currently describes `bates start`.

**Files:**

- `specs/cli.md`:
  - Delete the `### \`bates start\`` section (lines 9-30 in the current version, including the `Options` table).
  - Update the "Server Communication" example (around line 135) so the not-running message reads `Bates is not running. Start it with: batesd`.
  - In the "Configuration" section (around line 142), change "This can be overridden with the `--config` flag on `bates start`" to "This can be overridden with the `--config` flag on `batesd`."
  - In the "How It Connects" section (around line 149), change the `bates start` bullet to point at `batesd`. Suggested text: `**`batesd`** is the server. It launches the OTP application, which starts the ProcessSupervisor, Caddy, and the control interface (Phoenix). Run it directly in a terminal; future versions will install a launchd job via \`bates setup\`.`
  - Optionally add a new top-level subsection or a "## Daemon" / "## Server" section describing `batesd` and its `--config` flag, mirroring the structure the deleted `bates start` section had.

- `specs/system-overview.md`:
  - Update the `### CLI` section (around line 96-100) to mention the two binaries explicitly. Suggested rewrite:
    ```
    ### CLI

    Bates ships two binaries:

    - `batesd` is the server. It boots the OTP supervision tree, runs Caddy
      as a managed child process, and serves the JSON API and dashboard.
      Users invoke it directly in the foreground.
    - `bates` is a thin client for control commands. `bates env`,
      `bates status`, `bates up`, `bates down`, `bates restart`, and
      `bates setup` all speak to the running `batesd` over the JSON API
      (except `bates setup`, which is standalone).

    See [CLI](cli.md).
    ```

**Tests:** none — spec files are documentation.

### Phase 6 — Update README

The README currently has no instructions for running Bates. Add a short build/run section.

**Files:**

- `README.md`:
  - After the "Setup" section (which covers `caddy`, the resolver file, and `caddy trust`), add a "Build and Run" section:
    ```markdown
    ## Build and Run

    From `source/`:

    ```bash
    mix deps.get
    mix escript.build               # produces source/bates (the CLI)
    MIX_ENV=prod mix release batesd  # produces source/_build/prod/rel/batesd/
    ```

    Run the daemon:

    ```bash
    _build/prod/rel/batesd/bin/batesd
    ```

    Pass `--config <path>` to override the default config location
    (`~/.config/bates/config.toml`). Ctrl-C shuts the daemon down.

    The `bates` escript talks to the running daemon via the JSON API.
    With `bates` and `batesd` both on `$PATH`:

    ```bash
    bates status
    bates env myapp
    ```
    ```

**Tests:** none — README is documentation.

### Phase 7 — Smoke test the release end-to-end

This phase is manual and falls outside what the agent can verify autonomously. The agent's job is to make sure everything is in place; the user runs the smoke test.

**Procedure (for the user, documented in the PR):**

1. From `source/`: `MIX_ENV=prod mix release batesd`.
2. Build the escript: `mix escript.build`.
3. Run the daemon: `./_build/prod/rel/batesd/bin/batesd`.
4. Confirm: dashboard loads at `https://bates.test`; logs stream to stdout; the prereq check passes (assuming `bates setup` has been run).
5. In a second terminal: `./bates status`, `./bates up <some-app>`, `./bates env <some-app>`. Confirm each works against the running daemon.
6. In the daemon terminal: Ctrl-C. Confirm clean shutdown (services killed, Caddy stopped).
7. Try `--config /tmp/nonexistent.toml`: confirm the daemon either falls back gracefully or emits a clear error (depends on what `Bates.Config.applications/0` does for missing files — currently returns `[]` for `:enoent`).
8. Try running two `batesd` instances back to back: confirm the second exits with a port-bind error (no separate already-running probe).

The PR description should list these as `[ ]` items for the user to verify before merge.

## What Does NOT Change

- Six remaining control commands (`env`, `status`, `up`, `down`, `restart`, `setup`). Their argv parsing, output, exit codes, and JSON API interactions stay exactly as merged in PR #31.
- The supervision tree (`Registry`, `Phoenix.PubSub`, `Bates.ProcessSupervisor`, `BatesWeb.Endpoint`, `Bates.Caddy`).
- erlexec usage in `Bates.App` and `Bates.Caddy`.
- `Bates.CLI.Client` HTTP/SSL handling.
- The JSON API surface (`/status`, `/processes/:name/{start,stop,restart,logs}`).
- `Bates.Config` path resolution and the `:bates, :config_path` plumbing.
- The escript build output (`mix escript.build` still produces `source/bates`).
- `bates setup`'s behavior (shells out to `sudo` and `caddy trust`; no daemon needed).
- launchd integration (deferred to a v2 proposal).
- Homebrew packaging (separate follow-up proposal once the release artifact exists).

---

## Where to Start

> Non-authoritative pointers from the codebase survey at plan-creation time. Verify before acting.

**Code that comes out (Phase 1):**

- `source/lib/bates/cli/start.ex` — full file.
- `source/test/bates/cli/start_test.exs` — full file.
- `source/lib/bates/cli.ex:12` — the `dispatch(["start" | rest])` clause.
- `source/lib/bates/cli.ex:29` — the `bates start [--config <path>]` line in the `usage/0` heredoc.
- `source/test/bates/cli_test.exs:12` — the `assert output =~ "bates start"` line.

**Code that gets reworded (Phase 2):**

- `source/lib/bates/cli/client.ex:65` — `not_running_message/0` body.
- `source/test/bates/cli/client_test.exs` lines 86 and 93 — the assertion strings.
- `source/lib/bates/prerequisites.ex:3-23` — module docstring + `verify/0` docstring.
- `source/lib/bates/cli/setup.ex:3` — module docstring opening line.

**Code that grows (Phase 3):**

- `source/lib/bates/application.ex` — currently five lines in `start/2`. Add argv parsing and prereq check at the top.
- New `source/lib/bates/daemon.ex` if argv parsing grows beyond a few lines.
- New `source/test/bates/daemon_test.exs`.

**Build config (Phase 4):**

- `source/mix.exs` — add `releases:` keyword in `project/0`. Possibly add a private `rename_launcher/1` step.
- New `source/rel/overlays/bin/batesd` — the launcher override script.

**Specs and docs (Phases 5-6):**

- `specs/cli.md` — full file in scope.
- `specs/system-overview.md:96-102` — the `### CLI` section.
- `README.md` — append a "Build and Run" section after "Setup".

**Existing tests to verify still pass:**

- `source/test/bates/cli_test.exs` — dispatcher routing tests use `Bypass`; they should be unaffected by Phase 1's removal of the `start` clause.
- `source/test/bates/cli/client_test.exs` — Phase 2 updates two assertions.
- `source/test/bates/prerequisites_test.exs` (if it exists) — confirm Phase 2's docstring rewording doesn't break anything (docstrings aren't asserted).
- All other tests under `source/test/` — should pass unchanged.

**Reference for the application boot pattern:**

- `source/lib/bates/cli/start.ex` (before deletion) is the reference for what argv parsing + prereq verification should look like in `Bates.Application.start/2`. Steal the error formatting verbatim — same diagnostics, same exit codes — only the entry point changes.

---

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-05-03 01:15 PDT | READY | All input files exist and contain the code the plan claims. No hard blockers. Phase 3 hardened to lock in `Application.get_env(:bates, :skip_prereq_check, false)` (Mix is unavailable at release runtime). Phase 4 clarified for overlay-mechanic verification and `runtime.exs` non-requirement. Five POC gaps are downstream of work the plan proposes (need a built release artifact to verify) and resolve naturally during Phase 4/Phase 7. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

The plan is concrete, all referenced files exist with the expected contents, and the only real architectural ambiguity (`Mix.env/0` vs. `Application.get_env` for the test-skip gate) is now resolved in favor of the latter. Remaining "either/or" calls (overlay-mechanic option 1 vs option 2, `Bates.Daemon` module vs inline parsing) are within the agent's scope to decide during execution.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| `source/lib/bates/cli/start.ex` | Ready | Exists; `Bates.CLI.Start.run/1` matches plan's description. Will be deleted in Phase 1. |
| `source/test/bates/cli/start_test.exs` | Ready | Exists. Will be deleted in Phase 1. |
| `source/lib/bates/cli.ex:12` | Ready | `dispatch(["start" \| rest])` clause exactly as plan describes. |
| `source/lib/bates/cli.ex:29` | Ready | `bates start [--config <path>]` line in `usage/0` heredoc as expected. |
| `source/test/bates/cli_test.exs:12` | Ready | The `assert output =~ "bates start"` line exists. Removing it leaves six other subcommand assertions intact — the test remains useful. |
| `source/lib/bates/cli/client.ex:65` | Ready | `not_running_message/0` returns the expected string. |
| `source/test/bates/cli/client_test.exs:86,93` | Ready | Both assertions exist as plan describes. |
| `source/lib/bates/prerequisites.ex` | Ready | Module + `verify/0` docstrings reference `bates start`. |
| `source/lib/bates/cli/setup.ex:3` | Ready | Docstring opens with "One-time system setup for `bates start`." |
| `source/lib/bates/application.ex` | Ready | `start/2` is a 5-line pass-through to `Supervisor.start_link/2`. Clean slate for argv parsing + prereq check. |
| `source/lib/bates/config.ex` | Ready | `path/0` reads `Application.get_env(:bates, :config_path, default_path())`. Default is `~/.config/bates/config.toml`. |
| `source/config/` | Ready | Has `config.exs`, `test.exs`, `dev.exs`. No `prod.exs` or `runtime.exs`. `config.exs` does `import_config "#{config_env()}.exs"` — release ships with `:prod` and finds no env-specific file, which is fine. |
| `source/.gitignore` | Ready | `/_build/` is covered. |
| `source/rel/` | Missing (expected) | Created by Phase 4 (`source/rel/overlays/bin/batesd`). |
| `specs/cli.md` | Ready | `### bates start` section at lines 9-29; not-running example at line 135; `--config` reference at line 142; "How It Connects" bullet at 149-150. |
| `specs/system-overview.md` | Ready | `### CLI` section at lines 95-102 mentions `bates start`. |
| `README.md` | Ready | No existing "Build and Run" section. Phase 6 adds one after "Setup". |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `erlexec ~> 2.3` | Installed | `mix.exs:31`. Stays. |
| `releases:` in `mix.exs` | Not declared (expected) | Added by Phase 4. |
| `Mix.env/0` at release runtime | Unavailable (decided) | `Mix` is build-time only; not packaged into releases. Plan now uses `Application.get_env(:bates, :skip_prereq_check, false)` exclusively. |
| `config/runtime.exs` | Not present, not required | The only env-dependent setting (`--config <path>`) is read from argv. No release-time runtime config needed. |
| Elixir `~> 1.14` | OK | Mix releases are stable and well-supported in this range. |
| `source/test/bates/prerequisites_test.exs` | Exists | Phase 2 only changes docstrings; doesn't break this test. |

### Open Questions

| # | Question | Blocking? | Notes |
|---|----------|-----------|-------|
| 1 | Which overlay mechanic ends up working — custom `:steps` callback to rename the generated launcher, or direct script write? | No | Phase 4 prefers option 1 with option 2 as fallback. Verifiable during execution via `bin/batesd --help`. |
| 2 | Should `parse_argv/1` live inline in `Bates.Application.start/2` or in a separate `Bates.Daemon` module? | No | Phase 3 says: inline if it stays small (≤ 3 lines of orchestration), separate module otherwise. Agent decides. |
| 3 | Does `System.argv()` inside `Bates.Application.start/2` see clean user args under a `bin/batesd` launcher invocation? | No | Should be clean (Erlang strips BEAM flags before exposing argv). Verified during Phase 7 smoke test; the test for `--config /tmp/test.toml` will fail loudly if argv is mangled. |

### POC Gaps

| # | Assumption | Suggested POC | Why It Matters | Effort |
|---|-----------|---------------|----------------|--------|
| 1 | `MIX_ENV=prod mix release batesd` builds successfully on this codebase today | Build the release as part of Phase 4. If it fails, common causes are: missing `applications:` (plan includes it), unexpected runtime-config requirement (Phase 4 note covers fallback), ERTS mismatch (rare on a clean install). | Phase 4 cannot finish without this. | quick (during Phase 4) |
| 2 | The release overlay/`:steps` mechanic produces the correct `bin/batesd` entry point | After Phase 4 build: `_build/prod/rel/batesd/bin/batesd --help`. If output is mix-release subcommand help, the overlay didn't take. | If overlay fails, users get the mix-release subcommand interface instead of a daemon. | quick (during Phase 4) |
| 3 | `System.argv()` inside `start/2` sees clean `--config` args | Phase 7 smoke step: `bin/batesd --config /tmp/test.toml` — confirm `Application.get_env(:bates, :config_path)` is set to the expanded path. | If mangled, the daemon won't honor `--config`. | quick (during Phase 7) |
| 4 | The `config :bates, skip_prereq_check: true` line in `config/test.exs` is read at test time and the daemon prereq path skips correctly | `mix test` after Phase 3. Tests pass without `caddy` on `$PATH` and without `/etc/resolver/test`. | If misconfigured, `mix test` fails on dev machines that don't have `bates setup` run. | quick (during Phase 3) |

All four gaps are downstream of work the plan does and resolve naturally during execution. No pre-execution experiments are runnable (all require a built release artifact, which only exists after Phase 4).

### Pre-Work

None. The plan is execution-ready as written.

### Blockers

None identified.

---

## Execution Notes

### Assumptions Confirmed

- `MIX_ENV=prod mix release batesd` builds cleanly on this codebase (POC gap #1).
- `mix test` passes with `skip_prereq_check: true` in `config/test.exs` even on a machine without `caddy` on `$PATH` (POC gap #4).

### Deviations From Plan

- **Phase 3 — `skip_prereq_check` gate widened.** The plan said the flag skips only the prereq check. In practice, `mix test` invokes `Bates.Application.start/2` with `System.argv() == ["test"]`, which the new daemon argv parser rejects as a stray positional. Gated the entire `boot_daemon` orchestrator (argv parse + apply + prereq) on the flag, not just the prereq step. Same intent (don't trip on dev machines), broader scope.
- **Phase 3 — extracted `Bates.Daemon` module.** The plan said inline if `start/2` orchestration stays under three lines. The boot pipeline grew to four steps (`parse_argv` → `apply_options` → `apply_env` → `verify_prerequisites`); extracted into `Bates.Daemon` for testability. `start/2` stays a thin wrapper around `boot_daemon/0`.
- **Phase 4 — overlay mechanism abandoned for direct write.** The plan preferred option 1 (custom `:steps` callback to rename the generated launcher, then drop an overlay at `bin/batesd`). Sandbox restrictions made the overlay's `chmod +x` impossible to commit. Switched to the documented fallback: do the rename + write + `File.chmod!` entirely inside the `install_launcher/1` callback. No `source/rel/overlays/` directory exists in the final tree.
- **Phase 4 — added `config/prod.exs`.** Not in the plan. `config/config.exs` does `import_config "#{config_env()}.exs"` and the prod release fails to assemble without a `config/prod.exs`. Added a minimal stub mirroring `dev.exs` (Endpoint port 4080, secret_key_base, `:info` log level).
- **Phase 4 — env-var path for `--config`.** Big surprise mid-Phase 4: `_build/prod/rel/batesd/bin/batesd --config /x` did not honor the flag. Two stacked problems: (1) the mix-release `start` subcommand discards extra argv at the shell level, and (2) the `elixir` launcher's CLI mode interprets argv as `[script | args]`, so even after patching `start)` to forward `"$@"`, `--config` got read as a script filename and `start_cli` halted. Solved by having `bin/batesd` parse `--config` in shell, export it as `BATES_CONFIG_PATH`, then `exec batesd-orig start` with no argv. Added `Bates.Daemon.apply_env/1` to plumb the env var into `:bates, :config_path`. The argv path stays for `mix phx.server`; the env path covers the release. When both are set the env wins (the wrapper sets it deliberately).

### Gotchas Worth Documenting

- **`Mix.env/0` is unavailable in releases.** Plan called this out; confirmed during execution. The `skip_prereq_check` Application env var is the right approach.
- **Mix-release `start)` case discards argv.** Anyone trying to pass argv through the launcher will hit this. The env-var indirection is the cleanest workaround that doesn't require patching the upstream launcher template.
- **The escript no longer boots the OTP application.** Earlier work (commit `aaeb43f`) flipped `app: nil` in `mix.exs`'s `escript:` config so `bates env` doesn't accidentally start Caddy. This is unrelated to this plan but worth noting for context: the daemon path is `batesd` only; the escript is purely a JSON API client (plus `bates setup`, which shells out).

## Execution Stats

| Metric | Value |
|--------|-------|
| Duration | 00:51 → 01:18 (~27 minutes) |
| Files changed | 17 (vs `master`) |
| Commits | 7 |
| Tests added | 1 file (`source/test/bates/daemon_test.exs`, 11 tests) |
| Token totals (input / cache_create / cache_read / output) | _to be filled by launcher_ |
