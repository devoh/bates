# Plan: Mix Release for the Daemon

**Proposal:** [Mix Release for the Daemon](../proposals/accepted/2026-05-03-mix-release-for-daemon.md)

## Goal

Ship the Bates daemon as a Mix release named `batesd`, remove the broken `bates start` subcommand merged in PR #31, and move prerequisite + argv handling into `Bates.Application.start/2` so the same supervision tree boots correctly under `bin/batesd`.

## Why This Matters

The merged `bates start` command crashes immediately on a built escript because escripts can't carry `erlexec`'s `priv/exec-port` C binary. The escript packaging format is the wrong tool for the daemon. A Mix release embeds ERTS and includes priv directories, so erlexec finds its binary at runtime. The `bates` escript stays around for the six fast-cold-start control commands (`env`, `status`, `up`, `down`, `restart`, `setup`).

Users will invoke `batesd` directly to start the server. A future proposal will add launchd integration via `bates setup`.

## Acceptance Criteria

- [ ] `Bates.CLI.Start` module deleted.
- [ ] `start` clause removed from `Bates.CLI.dispatch/1`; `bates start` no longer appears in `Bates.CLI.usage/0` output.
- [ ] `source/test/bates/cli/start_test.exs` deleted.
- [ ] `Bates.CLITest`'s usage assertions updated — no assertion on `"bates start"` remaining.
- [ ] `Bates.CLI.Client.not_running_message/0` points users at `batesd`, not `bates start`. Tests updated to match.
- [ ] `Bates.Prerequisites` and `Bates.CLI.Setup` docstrings no longer reference `bates start`.
- [ ] `source/mix.exs` declares a `releases:` keyword with a `batesd` release.
- [ ] `MIX_ENV=prod mix release batesd` succeeds and produces `source/_build/prod/rel/batesd/bin/batesd`.
- [ ] `Bates.Application.start/2` parses `System.argv()` for `--config <path>`, runs `Bates.Prerequisites.verify/0`, and emits the same diagnostic + non-zero exit on failure that `bates start` did.
- [ ] An overlay at `source/rel/overlays/bin/batesd` makes `bin/batesd` (no subcommand) the foreground command. `bin/batesd --config /path/to/foo.toml` boots the supervision tree.
- [ ] `source/test/bates/daemon_test.exs` covers `--config` parsing (default + override) and the prereq exit path.
- [ ] `mix test` passes.
- [ ] `mix format --check-formatted` passes.
- [ ] `specs/cli.md`'s `### bates start` section removed; remaining `bates start` references updated to point at `batesd`.
- [ ] `specs/system-overview.md` mentions the two-binary topology and that `batesd` is the server entry point.
- [ ] `README.md` documents `mix release batesd` and how to run `batesd`.
- [ ] Manual smoke test: `_build/prod/rel/batesd/bin/batesd` boots, serves the dashboard at `https://bates.test`, Ctrl-C shuts it down. `bates status`, `bates up <name>`, and `bates env <name>` all work against the running daemon.

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
    3. Skip the prereq check when `Mix.env() == :test` (or use `Application.get_env(:bates, :skip_prereq_check, false)` if `Mix.env/0` isn't available at runtime in a release — confirm during execution which guard works inside the release tree).
    4. Otherwise run `Bates.Prerequisites.verify/0`. On `{:error, reason}`, write the same diagnostic Phase 4 of PR #31 emitted (`bates: prerequisite not met: <reason>\nRun \`bates setup\` to configure system prerequisites.\n`) to stderr and `System.halt(2)`.
  - Build and return the supervision spec exactly as today (`{:ok, _} = Supervisor.start_link(children(), opts)`).

**Notes:**

- `mix test` exercises the supervision tree implicitly via `start_permanent` — the prereq check must be skippable in test or it'll fail under any test environment without `caddy` on `$PATH` and `/etc/resolver/test`. Prefer `Mix.env() == :test` if it works in the release context; otherwise gate via `Application.get_env(:bates, :skip_prereq_check, true)` defaulting to `true` in `config/test.exs` and `false` in `config/prod.exs`. Pick the simpler one that passes both `mix test` and the release smoke test.
- A new module — `Bates.Daemon` — is acceptable if `start/2` becomes too large. Keep it under `source/lib/bates/daemon.ex` with a single `parse_argv/1` and `verify_prerequisites/0` API. If three or fewer lines of orchestration remain in `start/2`, leave it inline.

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

- Verify `source/.gitignore` already covers `/_build/` (it does) — no change needed.

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
