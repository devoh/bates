# Plan: Add CLI Commands

**Goal:** Implement `bates start`, `bates setup`, `bates status`, `bates up`,
`bates down`, and `bates restart`, completing the CLI surface documented in
`specs/cli.md`.

**Proposal:** [`workflow/proposals/accepted/2026-05-01-add-cli-commands.md`](../proposals/accepted/2026-05-01-add-cli-commands.md)

**Origin:** [tylerhunt/bates#6](https://github.com/tylerhunt/bates/issues/6)

## Why This Matters

Today the only path to running Bates is `mix phx.server` from the source
directory, and only `bates env` is wired up in the escript. Setup is a
copy-paste from the README. This work makes Bates installable, automates
first-run configuration, and gives users shell-driven control to match
the dashboard's visual surface.

## Acceptance Criteria

- [ ] `bates` (no args) prints multi-line usage listing all seven
      subcommands (`start`, `setup`, `status`, `up`, `down`, `restart`,
      `env`).
- [ ] `bates start --config <path>` boots the OTP supervision tree using
      the supplied config; defaults to `~/.config/bates/config.toml`.
- [ ] `bates start` exits non-zero with a `bates setup` pointer when
      `caddy` is missing from `$PATH` or `/etc/resolver/test` does not
      exist.
- [ ] `bates start` exits non-zero with `Bates is already running.` when
      a prior daemon is still up (probed via `GET /status`).
- [ ] Ctrl-C in `bates start` shuts down Caddy and the OTP supervision
      tree cleanly (no orphaned `caddy` process).
- [ ] `bates setup` creates `/etc/resolver/test` with `nameserver
      127.0.0.1` (sudo prompted) and runs `caddy trust`. Both steps are
      idempotent on re-run.
- [ ] `bates setup` exits non-zero with a diagnostic when
      `/etc/resolver/test` exists but contains content other than
      `nameserver 127.0.0.1`.
- [ ] `bates status` against an empty config prints headers only and
      exits 0.
- [ ] `bates status` renders single-service apps as one row and
      multi-service apps as an app row plus indented service rows,
      matching the spec sample.
- [ ] `bates up <name>`, `bates down <name>`, `bates restart <name>`
      announce `bates: started|stopped|restarted <name>` to **stdout**
      on success and exit 0.
- [ ] All six new commands exit non-zero with `Bates is not running.
      Start it with: bates start` to stderr when the daemon is down.
- [ ] All six new commands exit non-zero on API error (404/422/504),
      writing the response `reason` (or `error`) to stderr.
- [ ] `Bates.Caddy.init/1` no longer contains
      `check_caddy_in_path/0` or `check_resolver_file/0` — those checks
      live exclusively in the new `Bates.Prerequisites` module.
- [ ] `Bates.Config.applications/0` is zero-arg and reads the path from
      the application env (default `~/.config/bates/config.toml`).
- [ ] `bates env` continues to behave exactly as today (output, exit
      codes, eval-safety) after the shared HTTP plumbing extraction.
- [ ] `mix test` passes.

## Phases

### Phase 1: Shared Foundations

Land the small refactors that the new subcommands depend on. Each piece
is independently testable and does not change user-visible behavior on
its own.

**1a. Extract `Bates.CLI.Client`**

Move the `:httpc` startup, SSL options, JSON decoding, and transport-
error mapping out of `Bates.CLI.Env` into a new module.

Files:

- *new* `source/lib/bates/cli/client.ex` — `request/4` (or
  `get/1`/`post/2`), `transport_message/1`, `ensure_apps/0`,
  `ssl_options/0`. Public API returns `{:ok, status, body}` /
  `{:error, reason}` with body decoded to a map.
- `source/lib/bates/cli/env.ex` — replace inlined HTTP code with
  calls to `Bates.CLI.Client`.
- *new* `source/test/bates/cli/client_test.exs` — exercise transport-
  error mapping (`:nxdomain` and `{:failed_connect, _}` both produce
  the canonical "Bates is not running" message; other errors fall
  through).
- `source/test/bates/cli/env_test.exs` — verify behavior is unchanged
  after the refactor (expect minimal/no test edits).

**1b. Extract `Bates.Prerequisites`**

Move `check_caddy_in_path/0` and `check_resolver_file/0` out of
`Bates.Caddy` into their own module. Drop the warning-fallback in
`Bates.Caddy.init/1` — `bates start` is now the single gate.

Files:

- *new* `source/lib/bates/prerequisites.ex` — `verify/0` that returns
  `:ok | {:error, reason}` covering both checks.
- `source/lib/bates/caddy.ex` — remove
  `check_prerequisites/0`/`check_caddy_in_path/0`/`check_resolver_file/0`
  (lines ~344-369). `init/1` simplifies to
  `{:ok, %{pid: nil, os_pid: nil}, {:continue, :start_caddy}}`
  unconditionally; if Caddy fails to start, `start_caddy/0`'s existing
  error path still logs.
- *new* `source/test/bates/prerequisites_test.exs` — happy path,
  missing-caddy path, missing-resolver path. Use temp-path
  manipulation + `System.find_executable` mocking; if mocking is
  awkward, lean on integration assertion of the message strings.
- `source/test/bates/caddy_test.exs` — drop any tests that exercise
  the removed prereq guard.

**1c. Make `Bates.Config.applications/0` read the path from app env**

Files:

- `source/lib/bates/config.ex` — replace `@path "config.toml"` and the
  `applications/1` signature. New shape: `applications/0` (and
  optionally `applications/1` for tests) reads from
  `Application.get_env(:bates, :config_path, default_path())`. The
  default path is `Path.expand("~/.config/bates/config.toml")`,
  computed at call time (cheap; no need to cache).
- `source/lib/bates/process_supervisor.ex:55` — already calls
  `applications()` zero-arg. Verify it still compiles; no behavioral
  change.
- `source/lib/bates/caddy.ex:294` — same.
- `source/test/bates/config_test.exs` — update tests that pass a
  custom path. Tests should set `Application.put_env(:bates,
  :config_path, fixture_path)` in setup, and clear it in
  `on_exit`. Use `start_supervised`-style cleanup if multiple tests
  share the env key.

Verification: `mix test` passes; `bates env` still works against a
running daemon.

### Phase 2: Control Commands

Build the four read/write commands that wrap existing JSON API
endpoints. All four use `Bates.CLI.Client` from Phase 1.

**2a. `Bates.CLI.Status`**

Files:

- *new* `source/lib/bates/cli/status.ex` — `run/0`. Calls
  `Client.get("/status")`, renders the `processes[]` array as a
  fixed-width table. Empty list → headers only.
- *new* `source/lib/bates/cli/status/table.ex` (or inline in
  `Status` if simple enough) — column widths derived from data,
  single-service collapse, multi-service nesting, `—` for null
  hostname/port.
- *new* `source/test/bates/cli/status_test.exs` — empty config,
  single-service app, multi-service app with mixed statuses,
  transport error.

**2b. `Bates.CLI.Up`, `Down`, `Restart`**

Files:

- *new* `source/lib/bates/cli/up.ex` — `run/1`. POSTs to
  `/processes/<name>/start`. On 200, prints `bates: started <name>`
  to stdout and exits 0. Ignores `exports` in the response body.
- *new* `source/lib/bates/cli/down.ex` — `run/1`. POSTs to
  `/processes/<name>/stop`. On 200, prints `bates: stopped <name>`
  to stdout. On 422, prints `error` field to stderr.
- *new* `source/lib/bates/cli/restart.ex` — `run/1`. POSTs to
  `/processes/<name>/restart`. On 200, prints `bates: restarted
  <name>` to stdout.
- *new* `source/test/bates/cli/up_test.exs`,
  `source/test/bates/cli/down_test.exs`,
  `source/test/bates/cli/restart_test.exs` — happy path, transport
  error, 404, 422.

Verification: hand-test each command against a running daemon with a
config file containing a single-service and a multi-service app.

### Phase 3: `Bates.CLI.Setup`

Self-contained — does not depend on `Bates.CLI.Client` (`caddy trust`
and `sudo` are shell-outs) or any other Phase 1 module beyond a stylistic
preference for `Bates.Prerequisites`.

Files:

- *new* `source/lib/bates/cli/setup.ex` — `run/0`. Two steps:
  - Resolver: read `/etc/resolver/test` if it exists; if contents
    match `nameserver 127.0.0.1`, print `resolver: already
    configured`. If file is absent, shell out to `sudo bash -c '...'`
    via `System.cmd/3` (forwarding stderr). If file exists with
    different contents, print diagnostic to stderr and return non-
    zero.
  - Trust: shell out to `caddy trust` via `System.cmd/3` (forward
    stderr). Print `trust: configured` on exit 0; otherwise print
    Caddy's stderr passthrough and return non-zero.
  - Final summary line: `bates setup: ready` if both steps succeeded.
- *new* `source/test/bates/cli/setup_test.exs` — pure-Elixir tests
  for the resolver-content checking logic (split it into a pure
  helper that takes file contents → `:create | :ok | {:error, ...}`).
  The `sudo` and `caddy trust` shell-outs are not unit-tested; note
  this in the test file. Run hand-test on a clean machine.

Verification: hand-test on a system where `/etc/resolver/test` does
not exist, then re-run for idempotency, then mutate the file and
verify the diagnostic.

### Phase 4: `Bates.CLI.Start`

The biggest piece. Depends on Phase 1 (Client, Prerequisites, Config
plumbing).

Files:

- *new* `source/lib/bates/cli/start.ex` — `run/1`. Steps:
  1. Parse argv with
     `OptionParser.parse(argv, strict: [config: :string])`. Reject
     positional arguments and unknown switches with usage.
  2. If `--config` provided, `Application.put_env(:bates,
     :config_path, Path.expand(path))`.
  3. `Bates.Prerequisites.verify/0` → on error, print
     `bates: prerequisite not met: <reason>\nRun \`bates setup\` to
     configure system prerequisites.` to stderr, exit 2.
  4. Probe `Bates.CLI.Client.get("/status", timeout: 500)`. On
     `{:ok, 200, _}`, print `Bates is already running.` to stderr,
     exit 1. On error, proceed.
  5. `Application.ensure_all_started(:bates)`. On
     `{:error, {app, reason}}`, print to stderr and exit 1.
  6. Block: `receive do _ -> :ok end` (or
     `Process.sleep(:infinity)`). BEAM's default Ctrl-C handler
     terminates cleanly via the supervision tree's normal shutdown.
- *new* `source/test/bates/cli/start_test.exs` — argument parsing
  (rejects extras, unknown switches), prereq-failure path produces
  the right stderr/exit code. Skip the
  `Application.ensure_all_started/1` happy path test (it would clash
  with the test app already being started); document why.

Verification:

- `bates start` with `caddy` removed from `$PATH` produces the
  expected message and exit code.
- `bates start` with a fresh test config boots the daemon and
  `bates status` from another shell shows the apps.
- `bates start` while the daemon is running prints `Bates is already
  running.` and exits non-zero.
- Ctrl-C cleanly terminates the daemon (no orphan caddy in `ps`).

### Phase 5: Dispatcher, Usage, Specs, Verify

Wire the new subcommand modules into `Bates.CLI.dispatch/1`, expand
`usage/0` to a multi-line block, reconcile any spec drift, and run the
full suite.

Files:

- `source/lib/bates/cli.ex` — extend `dispatch/1` with clauses for
  `start`, `setup`, `status`, `up`, `down`, `restart`. Reject
  obviously-wrong shapes (extra args, missing names) at the
  dispatcher; per-command argument validation stays in each module.
  Update `usage/0`:

  ```
  Usage:
    bates start [--config <path>]
    bates setup
    bates status
    bates up <name>
    bates down <name>
    bates restart <name>
    bates env <name>
  ```

- `source/test/bates/cli_test.exs` — extend dispatch tests for each
  new clause and the updated usage block.
- `specs/cli.md` — re-read and reconcile with the final design. The
  spec already covers the contract; expect minor wording tweaks at
  most. Notably: the `bates env` "writes a single `bates: started
  <name>` line to stderr" sentence stays as-is (it's correct for
  `env`); ensure the `up`/`down`/`restart` sections aren't claiming
  stderr.
- `specs/control-interface.md` — verify; no changes expected (no new
  endpoints).
- *Run* `mix test` from `source/`. Hand-test the acceptance criteria
  list against a running daemon with the standard sample config.

## What Does NOT Change

- The `bates env` user-facing contract (output, stderr placement,
  `eval` safety, exit codes).
- The JSON API surface — no new endpoints, no shape changes to
  `/status`, `/processes/:name/start|stop|restart|logs`.
- HTTPS-via-Caddy as the only CLI transport. No localhost HTTP
  backdoor or Unix socket.
- Mix release packaging — escript stays.
- Linux support for `bates setup` — macOS-only in v1.
- `bates logs <name>` — endpoint exists but no subcommand in v1.
- Background/daemon mode for `bates start` — Ctrl-C is the only stop
  path.

---

## Where to Start

> These are pointers from the codebase survey at plan creation time.
> Files may have changed by execution time. Verify before acting.

**Core flow to trace (CLI invocation → control endpoints):**

- `source/lib/bates/cli.ex` — escript entrypoint and dispatcher.
- `source/lib/bates/cli/env.ex` — the canonical control-command
  pattern; new commands mirror its shape (HTTPS POST, error
  rendering, exit codes). Phase 1a refactors the HTTP plumbing out
  of here into `Bates.CLI.Client`.
- `source/lib/bates_web/router.ex:18-25` — JSON API routes already
  in place: `/status`, `/processes/:name/start|stop|restart|logs`.
- `source/lib/bates_web/controllers/process_controller.ex` — the
  endpoints' behavior. Already 404 / 422 / 504 / 200 with JSON
  bodies. New CLI commands consume this exactly as `bates env`
  does today.

**OTP boot path (relevant for `bates start`):**

- `source/lib/bates/application.ex` — supervision tree:
  `Registry`, `Phoenix.PubSub`, `Bates.ProcessSupervisor`,
  `BatesWeb.Endpoint`, `Bates.Caddy`.
- `source/mix.exs:12` — escript config: `app: nil` means OTP does
  not auto-start; `bates start` calls
  `Application.ensure_all_started(:bates)` explicitly.
- `source/lib/bates/caddy.ex:344-369` — current home of the
  prereq checks. Phase 1b moves these out.

**Configuration:**

- `source/lib/bates/config.ex:4` — `@path "config.toml"`. Phase 1c
  changes this to read from the application env.
- `source/lib/bates/process_supervisor.ex:55` — caller of
  `Bates.Config.applications()`.
- `source/lib/bates/caddy.ex:294` — second caller.

**Existing tests to mirror:**

- `source/test/bates/cli_test.exs` — dispatcher test patterns
  (capture_io, exit-code via send-to-self).
- `source/test/bates/cli/env_test.exs` — subcommand test patterns
  (Bypass-style fixture endpoint? Check the file for the exact
  approach).
- `source/test/bates_web/controllers/process_controller_test.exs` —
  reference for setting up an in-memory server for API-level tests.
- `source/test/bates/app_test.exs` — `start_supervised!` /
  `assert_eventually` patterns for app lifecycle.

**Spec reference:**

- `specs/cli.md` — the contract for all subcommands; lines 75-114
  cover `bates env` (stays as-is); lines around `bates status`
  contain the canonical table sample.
- `specs/control-interface.md` — JSON API shapes the CLI commands
  consume.

**Sample config for hand-testing:**

- `~/.config/bates/config.toml` (default path). For ad-hoc
  testing, run `bates start --config <fixture-path>` against a
  fixture config that defines at least one single-service app and
  one multi-service app.
