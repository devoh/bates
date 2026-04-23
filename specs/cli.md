# CLI

Conjure provides a command-line interface for launching the server,
managing applications, and performing system setup. Running `conjure`
with no arguments displays usage information.

## Commands

### `conjure start`

Starts the Conjure server in the foreground. Launches the OTP
supervision tree, starts Caddy, and begins streaming the interleaved
log output to stdout. Ctrl-C shuts everything down.

Before starting, checks that system prerequisites are in place:

1. `/etc/resolver/test` exists (DNS resolution for `*.test`).
2. Caddy's local CA root certificate is trusted (SSL termination).

If either check fails, prints a message pointing to `conjure setup`
and exits. Conjure does not attempt to fix prerequisites automatically.

#### Options

| Flag | Description |
|------|-------------|
| `--config <path>` | Path to the configuration file. Defaults to `~/.config/conjure/config.toml`. |

### `conjure setup`

Performs one-time system configuration that requires elevated
permissions:

1. Creates `/etc/resolver/test` to route all `*.test` DNS lookups to
   `127.0.0.1` (requires `sudo`).
2. Runs Caddy's certificate trust step to install the local CA root
   certificate into the macOS system trust store (Caddy prompts for a
   password).

Both steps are idempotent — running `conjure setup` again is safe.

### `conjure status`

Lists all configured applications and their current state. Requires
the server to be running.

```
$ conjure status
NAME       HOSTNAME          STATUS   PORT
myapp      myapp.test        up       52341
api        api.test          down     —
```

### `conjure up <name>`

Starts an application and all its services. Requires the server to be
running.

### `conjure down <name>`

Stops an application and all its services. Requires the server to be
running.

### `conjure restart <name>`

Stops then starts an application. Requires the server to be running.

## Server Communication

Control commands (`status`, `up`, `down`, `restart`) communicate with
the running server via the JSON API on `conjure.test`. If the server
is not running, they exit with a clear error message:

```
Conjure is not running. Start it with: conjure start
```

## Configuration

The default configuration file location is
`~/.config/conjure/config.toml`. This can be overridden with the
`--config` flag on `conjure start`.

See [Process Management](process-management.md) for the configuration
format.

## How It Connects

- **`conjure start`** launches the OTP application, which starts the
  ProcessSupervisor, Caddy, and the control interface (Phoenix).
- **`conjure setup`** is standalone — it does not require the server
  to be running.
- **Control commands** are thin wrappers around the JSON API defined in
  [Control Interface](control-interface.md). They format the response
  for terminal output.
