# CLI

Bates ships two binaries. `batesd` is the server (a Mix release that
boots the OTP supervision tree). `bates` is a thin client escript for
managing applications and performing system setup against a running
`batesd`. Running `bates` with no arguments displays usage
information.

## Commands

The Bates server itself is a separate binary, `batesd`. The `bates`
escript is a thin client for the control commands below; it does not
boot the OTP tree. See [System Overview](system-overview.md) for the
two-binary topology and [Daemon](#daemon) below for `batesd`'s flags.

### `bates setup`

Performs one-time system configuration that requires elevated
permissions:

1. Creates `/etc/resolver/test` to route all `*.test` DNS lookups to
   `127.0.0.1` (requires `sudo`).
2. Runs Caddy's certificate trust step to install the local CA root
   certificate into the macOS system trust store (Caddy prompts for a
   password).

Both steps are idempotent — running `bates setup` again is safe.

### `bates status`

Lists all configured applications and their current state. Requires
the server to be running.

```
$ bates status
NAME       HOSTNAME          STATUS   PORT
myapp                        up
  web      myapp.test        up       52341
  vite     vite.myapp.test   up       52342
  worker                     up       —
api        api.test          down     —
```

Single-service apps (like `api` above) show one row with no nesting.
Multi-service apps show the application row with derived status,
followed by indented service rows.

### `bates up <name>`

Starts an application and all its services. Requires the server to be
running.

### `bates down <name>`

Stops an application and all its services. Requires the server to be
running.

### `bates restart <name>`

Stops then starts an application. Requires the server to be running.

### `bates env <name>`

Prints shell-eval'able `export` lines for the union of exports
published by every service in the application. In v1, this is
effectively the addon exports (e.g., `PGHOST`, `PGPORT` from the
`postgresql` addon).

```
$ bates env myapp
export PGHOST='127.0.0.1'
export PGPORT='52345'
```

If the application is `down`, `bates env` triggers it to start —
there is no separate `bates up` step. The command blocks until each
service has either spawned (and produced its exports) or
terminal-failed, then prints the merged exports. After a cold boot
it writes a single `bates: started <name>` line to stderr; when the
application was already `up` the command stays silent on stderr.
The decision is based on the `status` field of the start response:
`up` means no boot occurred, anything else means the request
triggered one.

Output uses POSIX `export KEY='value'` syntax with single-quoted
values; embedded single quotes are escaped (`'\''`). Compatible with
bash and zsh. No alternate shell flavors are emitted in v1.

Intended for use in a project's `.envrc` so a console started in the
application directory inherits the same connection details its
services see:

```bash
# .envrc
eval "$(bates env myapp)"
```

The command exits 0 on success and non-zero on any failure (Bates
not running, application unknown, application crashed during start,
readiness timeout). Failure messages are written to stderr and no
output is written to stdout. Callers that want resilience in
`.envrc` (e.g., before Bates has been started for the day) can wrap
the call:

```bash
eval "$(bates env myapp 2>/dev/null || true)"
```

`direnv` caches `.envrc` evaluation; running `direnv reload` picks up
exports that changed since the shell loaded the file (for example,
after a stop/start cycle assigned a fresh `PGPORT`).

## Daemon

The server is a separate binary named `batesd`, built as a Mix release
(`MIX_ENV=prod mix release batesd`). It boots the OTP supervision
tree, runs Caddy as a managed child process, and serves the JSON API
and dashboard. Run it directly in a terminal — Ctrl-C shuts it down.

Before bringing the supervision tree up, `batesd` checks that system
prerequisites are in place:

1. `caddy` is on `$PATH`.
2. `/etc/resolver/test` exists (DNS resolution for `*.test`).

If either check fails, `batesd` writes a diagnostic pointing at
`bates setup` to stderr and exits with code 2. Bates does not attempt
to fix prerequisites automatically. Caddy's local CA root certificate
trust is set up during `bates setup`, not gated here.

A future proposal will install a launchd job via `bates setup` so
`batesd` is system-supervised; until then users invoke it manually.

### Options

| Flag | Description |
|------|-------------|
| `--config <path>` | Path to the configuration file. Defaults to `~/.config/bates/config.toml`. |

## Server Communication

Control commands (`status`, `up`, `down`, `restart`, `env`)
communicate with the running server via the JSON API on `bates.test`.
If the server is not running, they exit with a clear error message:

```
Bates is not running. Start it with: batesd
```

## Configuration

The default configuration file location is
`~/.config/bates/config.toml`. This can be overridden with the
`--config` flag on `batesd`.

See [Process Management](process-management.md) for the configuration
format.

## How It Connects

- **`batesd`** is the server. It launches the OTP application, which
  starts the ProcessSupervisor, Caddy, and the control interface
  (Phoenix). Run it directly in a terminal; future versions will
  install a launchd job via `bates setup`.
- **`bates setup`** is standalone — it does not require the server
  to be running.
- **Control commands** are thin wrappers around the JSON API defined in
  [Control Interface](control-interface.md). They format the response
  for terminal output.
