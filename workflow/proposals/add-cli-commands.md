# Add CLI Commands — Proposal

**Status:** Draft
**Date:** 2026-05-01
**Author:** Tyler + Claude
**Origin:** https://github.com/tylerhunt/bates/issues/6
**Synced:** 2026-05-01 (no comments on issue)

## Summary

Build out the `bates` command-line interface so the server is launched
and managed without touching `mix`. Add `start` (foreground daemon),
`setup` (one-time system configuration), and the control commands
`status`, `up`, `down`, and `restart`. The control commands are thin
HTTPS wrappers around the existing JSON API on `bates.test`, mirroring
the pattern already shipped for `bates env`. `start` is the only new
subcommand that boots the OTP application and supervises Caddy. `setup`
is standalone and does not need a running server.

The dispatcher seed in `lib/bates/cli.ex` and the per-subcommand module
pattern (`lib/bates/cli/env.ex`) introduced for `bates env` are already
shaped for this work; this proposal extends them rather than refactoring.

---

## Problem

Today the only way to run Bates is `mix phx.server` from the source
directory. The `bates` escript exists, but only `bates env` is wired up
— there is no published path for users to start the server, configure
prerequisites, or interact with running applications from a shell.
The spec (`specs/cli.md`) has documented the full CLI surface for some
time; this proposal closes that gap.

Specific pain points:

- **No daemon launcher.** Users must clone the source repo and run a
  Mix task to start Bates. There is no installable command.
- **Prerequisite setup is manual.** `README.md` instructs users to
  `sudo bash -c 'echo "nameserver 127.0.0.1" > /etc/resolver/test'` and
  run `caddy trust` by hand. This is a one-time operation that belongs
  inside the tool, not a copy-paste from documentation.
- **Prerequisite checks live in the wrong place.** `Bates.Caddy` checks
  for `caddy` on the path and `/etc/resolver/test` during its
  `init/1` and merely logs a warning if either is missing
  (`source/lib/bates/caddy.ex:344-369`). The server then boots into a
  half-functional state. The spec calls for prerequisites to be checked
  before boot, with a clear pointer to `bates setup`.
- **No shell-friendly inspection or control.** A user with the server
  running cannot easily ask "what's up?" or "stop myapp" without
  hitting the JSON API by hand. The dashboard at `bates.test` covers
  the visual case; the CLI is needed for scripting, automation, and
  terminal-only workflows.

The core design questions — endpoints, JSON shapes, blocking semantics,
PubSub topology — are already settled by previous proposals
(`#4 core-vertical-slice`, `#27 bates env`, `#19 addons`). What's left is
the CLI front-end and the daemon entrypoint.

---

## Decided

The contract from issue #6 stands:

- **Six subcommands.** `start`, `setup`, `status`, `up <name>`,
  `down <name>`, `restart <name>`. (`env <name>` already exists from
  #27 and is not changed by this proposal.)
- **`bates start` is foreground-only.** Boots the OTP supervision
  tree, starts Caddy, streams interleaved log output to stdout, exits
  on Ctrl-C. No detach/daemonize flag in v1.
- **`--config <path>` is on `start` only.** Defaults to
  `~/.config/bates/config.toml`. Other subcommands implicitly use
  whatever config the running server was started with.
- **Prerequisite checks gate `start`.** Before booting, verify
  `/etc/resolver/test` exists and Caddy's local CA is trusted. On
  failure, print a message pointing to `bates setup` and exit non-zero.
  Bates does not attempt to fix prerequisites automatically.
- **`bates setup` is standalone.** Performs `/etc/resolver/test`
  creation (requires `sudo`) and `caddy trust`. Both steps are
  idempotent. Does not require a running server.
- **Control commands talk to the JSON API on `bates.test`.** Same
  HTTPS-via-Caddy transport as `bates env`. If the server is not
  running, exit with `Bates is not running. Start it with: bates
  start`.
- **`bates status` output format.** Two-tier table with one row per
  app and indented rows for each service in multi-service apps.
  Single-service apps collapse to one row. Spec sample:

  ```
  $ bates status
  NAME       HOSTNAME          STATUS   PORT
  myapp                        up
    web      myapp.test        up       52341
    vite     vite.myapp.test   up       52342
    worker                     up       —
  api        api.test          down     —
  ```

Carry-overs from earlier work that this proposal extends:

- **Dispatcher seed.** `lib/bates/cli.ex` already validates argv and
  dispatches to per-subcommand modules. New subcommands are added as
  new modules + dispatcher clauses, not by ripping out the entrypoint.
- **HTTPS via Caddy is the only transport.** No localhost-only HTTP
  backdoor or Unix socket. The CLI uses the system trust store via
  `:httpc` with verified peer SSL, exactly as `cli/env.ex` does today.
- **Errors go to stderr; success goes to stdout.** Same convention as
  `bates env`. Non-zero exit on any failure.
- **API responses are JSON.** No plain-text or empty bodies, even for
  errors. (Already a global rule in this codebase per memory.)

---

## Codebase Context

> Non-authoritative. Code may change before this proposal is accepted
> or executed. These are pointers to help orient, not implementation
> instructions.

**Existing CLI surface:**

- `source/lib/bates/cli.ex` — minimal dispatcher, currently routes
  `["env", name]` to `Bates.CLI.Env.run/1` and prints
  `Usage: bates env <name>` on anything else. Argument validation was
  recently consolidated here (commit `4341e78`).
- `source/lib/bates/cli/env.ex` — the `bates env` implementation:
  HTTPS POST to `/processes/<name>/start`, formats `exports` as
  `export KEY='value'` lines, single-line stderr cold-boot announce.
  This is the pattern other control commands extend.
- `source/test/bates/cli_test.exs` and
  `source/test/bates/cli/env_test.exs` — test patterns for the
  dispatcher and a subcommand. New subcommands need parallel tests.

**Escript packaging:**

- `source/mix.exs:12` declares
  `escript: [main_module: Bates.CLI, name: "bates", app: nil]`. The
  `app: nil` setting (commit `aaeb43f`, "Stop escript from booting the
  OTP application") prevents the OTP application from starting on
  every invocation, so control commands cold-start cheaply. `bates
  start` is the only subcommand that needs the OTP app loaded; today
  there is no code path that explicitly starts it from the escript.

**OTP boot today:**

- `source/lib/bates/application.ex` defines the supervision tree:
  `Registry`, `Phoenix.PubSub`, `Bates.ProcessSupervisor`,
  `BatesWeb.Endpoint`, `Bates.Caddy`. Started today only via `mix
  phx.server` (or test setup).
- `source/lib/bates/caddy.ex:344-369` holds the prerequisite checks
  (`check_caddy_in_path/0`, `check_resolver_file/0`). They run inside
  Caddy's `init/1` and currently log warnings rather than failing
  boot. These need to move (or be invoked from) `bates start` so
  `start` can fail with a useful message before the supervision tree
  comes up.

**Control endpoints (already exist):**

`source/lib/bates_web/controllers/process_controller.ex` and
`source/lib/bates_web/router.ex`:

- `GET  /status` — lists all configured applications and their derived
  status, with nested service rows (name, hostname, status, port).
  The exact shape `bates status` needs is already produced.
- `POST /processes/:name/start` — blocking start with merged exports.
  `bates up` is a thin wrapper that ignores the exports payload and
  reports status.
- `POST /processes/:name/stop` — synchronous stop. `bates down` wraps
  this.
- `POST /processes/:name/restart` — synchronous stop+start. `bates
  restart` wraps this.

The existing endpoints already encode every behavior the new
control commands need (idempotency, 404 on unknown app, 422 on
crash, JSON shape). No new endpoints are added by this proposal.

**Configuration loading:**

- `source/lib/bates/config.ex:4` has `@path "config.toml"` as the
  default. `applications/1` accepts a path argument but the supervisor
  calls it without one. To honor `--config`, the path needs to thread
  from CLI → application env → `Config.applications/1` →
  `Bates.ProcessSupervisor`.
- `source/lib/bates/process_supervisor.ex` (and `caddy.ex:294`) call
  `Bates.Config.applications()` with no argument; they would read
  from the application env (or a wrapper module) instead.

**Setup steps in the wild:**

- `README.md:18-41` documents the manual setup flow:
  `brew install caddy`, `sudo bash -c '...resolver/test'`, `caddy
  trust`. `bates setup` automates the latter two. (Caddy install
  itself is out of scope — Bates checks for it but does not install
  it; that's already how `Caddy.check_caddy_in_path/0` behaves.)

**Tests for the JSON API:**

- `source/test/bates_web/controllers/process_controller_test.exs`
  covers the endpoints. CLI-level tests for the new control commands
  use the same patterns as `cli/env_test.exs`: a fixture endpoint, a
  captured-IO assertion, an exit code assertion.

**Spec coverage already in place:**

- `specs/cli.md` documents all six subcommands plus `env`. Spec
  changes for this work are minor — fold any decisions made during
  refinement back into the spec, but the contract is largely already
  written.
- `specs/control-interface.md` already documents the JSON API shape
  the control commands wrap.

---

## Proposed Design

### Distribution: escript-only, with `bates start` loading the OTP app

Keep the existing escript packaging (`mix.exs:12`). Do not introduce a
Mix release. `bates start` is the one subcommand that needs the OTP
application running, and it loads it explicitly:

```elixir
def run(opts) do
  with :ok <- check_prerequisites(),
       :ok <- put_config_path(opts[:config]),
       {:ok, _} <- Application.ensure_all_started(:bates) do
    block_until_signal()
  end
end
```

`app: nil` stays in `mix.exs` so control commands keep their fast
cold-start. The OTP app's deps (Phoenix, Bandit, Phoenix PubSub,
erlexec, Toml, Jason) ride along inside the escript bundle as today.

If the escript-bundled-Phoenix path proves too brittle in practice
(static asset paths from `priv/static`, etc.), fall back to a Mix
release as a follow-up. Not a v1 concern given there is no static
asset pipeline today (LiveView renders from compiled templates, not
the priv directory).

### Foreground lifecycle and Ctrl-C

`bates start` blocks the main escript process after
`Application.ensure_all_started/1` returns. Two viable paths:

- **Receive-loop on a never-arriving message.** Simple,
  signal-handled by the BEAM's default Ctrl-C → graceful shutdown.
- **Trap SIGINT explicitly** via `:erlang.trap_exit` and a custom
  handler. More control over shutdown ordering but more code.

Default to the receive-loop unless we discover Ctrl-C does not cleanly
terminate Caddy via `:exec.run_link`'s monitor (it should — the link
propagates exit). The Caddy GenServer already monitors the Caddy OS
process and cleanly terminates it on shutdown via its `terminate/2`
(implicit via `:exec` link).

### Prerequisite checks as `bates start`'s gate

Move the existing checks out of `Bates.Caddy.init/1`:

- `check_caddy_in_path/0` and `check_resolver_file/0` become public
  functions on a `Bates.Prerequisites` (or similar) module, or stay on
  `Bates.Caddy` as `verify/0`.
- Add a third check for **CA trust**. Realistic options:
  - Run `caddy trust --check` (if it exists) or parse `caddy
    untrust --help` for a dry-run flag.
  - Open an HTTPS connection to `https://bates.test` and observe
    whether peer verification succeeds. Requires the server to be
    running, so not viable here.
  - Read the keychain via `security find-certificate -c "Caddy Local
    Authority - <date>" /Library/Keychains/System.keychain`. Brittle
    across Caddy versions.
  - Defer the trust check entirely in v1: rely on `caddy trust` being
    idempotent and let the user re-run `bates setup` if HTTPS doesn't
    work.

  Pick during refinement (Open Question 1).
- `bates start` calls these before `Application.ensure_all_started`.
  On failure, print:

  ```
  bates: prerequisite not met: /etc/resolver/test missing
  Run `bates setup` to configure system prerequisites.
  ```

  ...to stderr, exit 2.
- `Bates.Caddy.init/1` no longer needs the prereq guard — but keeps
  it (as a defensive fallback) for the `mix phx.server` development
  path. Or move it entirely. Open Question 2.

### `bates setup`

Two idempotent steps, run sequentially:

1. **Resolver file.**
   - If `/etc/resolver/test` exists and contains `nameserver
     127.0.0.1`, skip with `resolver: already configured`.
   - Otherwise: shell out to `sudo bash -c 'mkdir -p /etc/resolver &&
     echo "nameserver 127.0.0.1" > /etc/resolver/test'`. `sudo` is
     interactive; the user is prompted for a password by sudo itself.
     The CLI prints `resolver: created` on success.

2. **Caddy CA trust.**
   - Shell out to `caddy trust`. Caddy is also interactive (its own
     password prompt for keychain modification on macOS). Caddy's own
     output is forwarded.
   - Print `trust: configured` on success.

The CLI prints a one-line summary at the end:
`bates setup: ready (or `re-run if any step failed`).

If `/etc/resolver/test` already exists but does not contain
`nameserver 127.0.0.1`, treat as a hard error and exit non-zero with a
diagnostic — do not silently overwrite a hand-edited resolver file.

### Control commands: shape and HTTPS layout

The control commands all share the same skeleton, already established
by `cli/env.ex`:

```elixir
def run(args) do
  case http_request(method, path, body) do
    {:ok, status, body} when status in 200..299 -> render_success(body)
    {:ok, _status, body} -> render_error(body); 1
    {:error, reason} -> stderr(transport_message(reason)); 1
  end
end
```

Refactor opportunity (probably worth it now that we have four
HTTP-talking commands): extract the common bits — `:httpc` startup,
SSL options, JSON decoding, transport-error mapping — into a small
`Bates.CLI.Client` module. `bates env` migrates to use it; `status`,
`up`, `down`, `restart` are written against it.

Per-command specifics:

- **`bates status`** → `GET /status`. Render rows from
  `processes[].services[]`. Multi-service apps (services with
  `length > 1`) print an app row (name only, app-level status from the
  derived rollup) followed by indented service rows. Single-service
  apps print one row with the app name in the NAME column. Use a
  fixed-width table renderer; an `—` for null hostname/port.
- **`bates up <name>`** → `POST /processes/<name>/start`. On 200,
  exit 0 silently (or print `bates: started <name>` to stderr — Open
  Question 3). On 404, 422, 504: print `reason` to stderr, exit 1.
- **`bates down <name>`** → `POST /processes/<name>/stop`. On 200,
  exit 0 silently (or `bates: stopped <name>`). On 422, print
  `error`, exit 1.
- **`bates restart <name>`** → `POST /processes/<name>/restart`.
  Same as down.

### `--config <path>` plumbing

`bates start --config /path/to/config.toml` writes the absolute path
into the application env before starting:

```elixir
:ok = Application.put_env(:bates, :config_path, Path.expand(path))
```

`Bates.Config.applications/0` becomes a zero-arg function that reads
from `Application.get_env(:bates, :config_path, "~/.config/bates/config.toml" |> Path.expand())`.
Existing callers (`ProcessSupervisor`, `Caddy`) are unchanged. Tests
that need a custom path use `Application.put_env` in their setup.

The default path expands `~/.config/bates/config.toml` once at boot;
no per-call expansion. If the file does not exist at the resolved
path, `Config.applications/0` returns `[]` today — that behavior is
fine for `bates start` against an empty config (Bates boots, no apps
are defined). Print a warning, but don't fail.

### Subcommand dispatcher growth

The current dispatcher is two clauses: `["env", name]` and a
catch-all. Extend to:

```elixir
def dispatch(["start" | rest]),         do: Bates.CLI.Start.run(rest)
def dispatch(["setup"]),                  do: Bates.CLI.Setup.run()
def dispatch(["status"]),                 do: Bates.CLI.Status.run()
def dispatch(["up", name]),               do: Bates.CLI.Up.run(name)
def dispatch(["down", name]),             do: Bates.CLI.Down.run(name)
def dispatch(["restart", name]),          do: Bates.CLI.Restart.run(name)
def dispatch(["env", name]),              do: Bates.CLI.Env.run(name)
def dispatch(_),                          do: usage()
```

`usage/0` updates to a multi-line block listing all subcommands. Each
subcommand keeps its own validation (e.g., `Up.run/1` rejects nil),
but the dispatcher rejects obviously-wrong shapes (no name, extra
args). Same pattern as today.

---

## What This Unlocks

1. **Bates becomes installable.** A single `bates` binary
   distributed via `mix escript.install` (or a Homebrew formula
   later) is everything a user needs after `brew install caddy`. No
   source clone, no `mix phx.server`.
2. **Friction-free first-run setup.** `bates setup` removes the
   copy-paste-from-README step. New users go from `brew install caddy`
   to `bates setup` to `bates start` without leaving the CLI.
3. **Scripting and automation.** `bates up myapp && curl
   https://myapp.test/health` becomes a one-liner. CI environments,
   shell aliases, and developer workflows can drive Bates without
   knowing about the JSON API.
4. **A single source of truth for "what's running".** `bates status`
   replaces ad-hoc `curl bates.test/status | jq` in user shell
   history.
5. **Closes the spec gap.** `specs/cli.md` has documented this CLI
   for several iterations; the implementation finally catches up.

---

## Scope

In scope:

- New CLI subcommand modules: `Bates.CLI.Start`, `Bates.CLI.Setup`,
  `Bates.CLI.Status`, `Bates.CLI.Up`, `Bates.CLI.Down`,
  `Bates.CLI.Restart`.
- Extraction of HTTP/SSL/transport plumbing from `Bates.CLI.Env` into
  `Bates.CLI.Client` (or similar). `Env` migrates to use it.
- Movement of prerequisite checks out of `Bates.Caddy.init/1` into a
  function that `bates start` invokes before
  `Application.ensure_all_started/1`. (Caddy keeps a defensive
  fallback or not — Open Question 2.)
- A CA-trust prerequisite check to be added (Open Question 1).
- `--config <path>` flag on `bates start`. Plumb through application
  env into `Bates.Config.applications/0`.
- Default config path of `~/.config/bates/config.toml`, expanded once
  at boot.
- Dispatcher updates and a multi-line `usage/0`.
- Status table rendering: a small formatter helper that handles
  fixed-width columns and the single-service / multi-service shapes
  defined in `specs/cli.md`.
- Tests:
  - One per subcommand: success path, transport error ("Bates is not
    running"), API error (404/422/504), argument validation.
  - `bates start`: prerequisite-missing path exits with the right
    message; happy path successfully `Application.ensure_all_started/1`'s.
    (Probably hard to test the foreground-block; skip if so.)
  - `bates setup`: idempotency on second run; rejects a
    differently-configured `/etc/resolver/test`. Caddy trust step is
    likely shelled-out and not unit-tested — note in the test file.
  - `bates status`: golden rendering for empty config, single-service
    app, multi-service app with mixed statuses.
- Spec touch-ups: anything that drifted between `specs/cli.md` and
  the final design (probably minimal — the spec is already
  comprehensive).

Out of scope:

- **Mix release packaging.** Stick with escript. If escript proves
  inadequate for `bates start`, that's a follow-up proposal.
- **Background/daemon mode.** No `bates start --detach` or `bates
  stop` (the daemon). Ctrl-C is the only stop path. Process
  management of Bates itself (launchd, systemd, etc.) is the user's
  problem.
- **Subcommand `--help`.** `bates` with no args prints usage; that's
  the only help surface. No per-subcommand help in v1.
- **Linux support for `bates setup`.** Resolver-file path is macOS-
  specific (`/etc/resolver/`). Linux uses different DNS plumbing
  (`systemd-resolved`, NetworkManager, `/etc/hosts`). Tracked
  separately if/when Linux support is in scope.
- **Caddy install automation.** Bates checks for it; the user
  installs it. (Same as today.)
- **Auto-restart on config file change.** `bates start` reads the
  config once at boot. SIGHUP / file-watching is a follow-up.
- **`bates logs <name>`.** Not in issue #6. The endpoint exists
  (`GET /processes/:name/logs`) but no spec'd subcommand. Defer.
- **`bates env <name>` changes.** Already shipped; this proposal
  doesn't touch its behavior, only refactors shared HTTP plumbing
  underneath it.

---

## Open Questions

1. **CA trust verification.** What's the actual mechanism for `bates
   start`'s prerequisite "Caddy's local CA root certificate is
   trusted" check? Options:
   - Defer it entirely — assume idempotent `caddy trust` is enough,
     skip a runtime check, and let users re-run `bates setup` if
     browsers reject `bates.test`.
   - Inspect the macOS keychain via `security find-certificate -c
     "Caddy Local Authority" /Library/Keychains/System.keychain`.
     Brittle across Caddy versions; likely good enough.
   - Open an internal SSL handshake to a known port to verify.
     Requires server-up which defeats the purpose of a pre-boot
     check.

   Recommended: defer. Caddy's trust step is fast and idempotent;
   `bates setup` re-runs it. A failed-trust scenario surfaces as a
   browser warning, not a Bates crash.

2. **Where do prerequisite checks live in the supervision tree?** Two
   options after movement out of `Bates.Caddy.init/1`:
   - Run only from `bates start` (before
     `Application.ensure_all_started`). `mix phx.server` users skip
     them. Caddy's `init/1` no longer guards.
   - Run from both — `bates start` for fail-fast UX, and
     `Caddy.init/1` as a defensive fallback that logs warnings (today's
     behavior).

   Recommended: option 2. Cheap to keep both. The Caddy fallback
   exists for the `mix phx.server` development path that we don't
   want to break.

3. **Output on success for `bates up` / `down` / `restart`.** Three
   styles in play:
   - Silent on success (Unix tradition). User checks exit code.
   - One-line stderr `bates: started myapp` (matches `bates env` cold-
     boot behavior).
   - One-line stdout `myapp: up`.

   Recommended: option 2 for `up`, option 1 (silent) for `down` and
   `restart`. Asymmetric, but `up` is the only one with an obvious
   "I just did something noticeable" outcome (and the precedent from
   `bates env`).

4. **Status output when no apps are configured.** Three options:
   - Print headers only.
   - Print `No applications configured.` to stderr, exit 0.
   - Print `No applications configured.` to stderr, exit 1.

   Recommended: option 1. Headers-only is the most script-friendly
   and matches `ls` on an empty directory (silent, exit 0).

5. **`bates setup` and a hand-edited `/etc/resolver/test`.** If the
   file exists but doesn't contain `nameserver 127.0.0.1`, what
   should `setup` do?
   - Refuse and exit non-zero with a diagnostic (proposed behavior).
   - Append the line.
   - Overwrite.

   Recommended: option 1. Resolver files are typically tiny; if a
   user has customized theirs, silently overwriting is hostile.

6. **Concurrent `bates start` invocations.** What's the failure mode
   when Bates is already running and the user runs `bates start`
   again? The Phoenix endpoint will fail to bind port 4080 and the
   supervision tree will crash on init. Should we add a
   "Bates is already running" probe via the JSON API before booting,
   to give a clean error?

   Recommended: yes — a quick `GET /status` against `bates.test` with
   a short timeout before booting. If it succeeds, exit non-zero with
   `Bates is already running.`. Cheap, mirrors the inverse check the
   control commands do.

7. **Argv parser.** Today the dispatcher pattern-matches argv lists.
   For `--config <path>` we need at least minimal flag parsing.
   - Use `OptionParser.parse/2` (stdlib).
   - Hand-roll argv splitting in `Bates.CLI.Start`.

   Recommended: `OptionParser`. It's stdlib, free, and saves us from
   writing a worse one. Keep the dispatcher itself argv-list-based;
   `Start.run/1` is the only command with flags in v1.
