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

### `bates up [<name>]`

Starts an application or a single service within one. Requires the
server to be running.

- `bates up <app>` boots every service in the application.
- `bates up <app>:<service>` boots the named service plus every
  service it transitively `depends_on`.
- `bates up` (no name) resolves the application from the current
  working directory — see [Working Directory Resolution](#working-directory-resolution).
- `bates up :<service>` resolves the application from the current
  working directory and boots the named service within it.

Both forms clear the application's paused flag, so subsequent
on-demand DNS-driven startup proceeds normally.

On success, the command writes one of:

```
bates: started <app>
bates: started <app>:<service>
```

A name with no colon hits the application-level endpoint; a name of
the form `<app>:<service>` hits the per-service endpoint. Names with
more than one colon are rejected with a usage error and exit code 2.

### `bates down [<name>]`

Stops an application or a single service within one, and marks the
application as paused so the loading page intercepts further
on-demand startup. Requires the server to be running.

- `bates down <app>` stops every service in the application.
- `bates down <app>:<service>` stops the named service and every
  service that transitively `depends_on` it (reverse-topological
  cascade).
- `bates down` (no name) resolves the application from the current
  working directory — see [Working Directory Resolution](#working-directory-resolution).
- `bates down :<service>` resolves the application from the current
  working directory and stops the named service within it (with the
  same dependents cascade).

The per-service form's success line includes the cascaded list when
non-empty:

```
bates: stopped <app>:<service>
bates: stopped <app>:<service> (also stopped: <other1>, <other2>)
```

A user-initiated `down` (application-level or per-service) sets the
application's paused flag. The flag is cleared by a user-initiated
`up`. The loading page checks the flag before starting an
application on demand; while paused, browsers see a paused page
with a Resume button and non-HTML clients get a 503 JSON response.

Same parsing rules as `bates up`: multi-colon names exit with code 2.

### `bates restart [<name>]`

Stops then starts an application. Requires the server to be running.
With no name, the target application is resolved from the current
working directory — see [Working Directory Resolution](#working-directory-resolution).

There is no per-service form. `bates restart myapp:web` exits with
code 2 and writes a usage error pointing at the explicit two-step
workaround:

```
bates restart does not support per-service form;
use 'bates down <app>:<service>' followed by 'bates up <app>:<service>'
```

The decision avoids the easy-to-hit stale-export window that a
per-service restart would introduce: a downstream service's
environment is seeded from its dependencies' exports at start time,
and per-service restart would not refresh the seeded environment of
dependents.

### `bates env [<name>]`

Prints shell-eval'able `export` lines for the application's exports —
the merge of static exports (config-derived values like `HOST`) and
the dynamic exports published by the application's addons (e.g.,
`PGHOST`, `PGPORT` from the `postgresql` addon). With no name, the
target application is resolved from the current working directory —
see [Working Directory Resolution](#working-directory-resolution).

```
$ bates env myapp
export HOST='myapp.test'
export PGHOST='127.0.0.1'
export PGPORT='52345'
```

`bates env` starts the application's addons if they're not already
up — but it does **not** start the application's own service. That's
`bates up`'s job. The decoupling means a slow or crashing app service
never holds up directory entry: `bates env` blocks only on the
addons, which are typically fast to start (Postgres boots in under a
second).

The command blocks until each addon has either become ready or
terminal-failed, then prints the merged exports. After a cold boot
it writes a single `bates: started <name>` line to stderr; when the
addons were already `up` the command stays silent on stderr. The
decision is based on the `status` field of the response: `up` means
no boot occurred, anything else means the request triggered one.

Output uses POSIX `export KEY='value'` syntax with single-quoted
values; embedded single quotes are escaped (`'\''`). Compatible with
bash and zsh. No alternate shell flavors are emitted in v1.

Intended for use in a project's `.envrc` so a console started in the
application directory inherits the same connection details the
application's services see:

```bash
# .envrc
eval "$(bates env myapp)"
```

The command exits 0 on success and non-zero on any failure (Bates
not running, application unknown, an addon crashed during start,
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

### Working Directory Resolution

When `up`, `down`, `restart`, or `env` is invoked without a name, the
CLI asks the daemon to look up the application whose configured
`root` is the deepest ancestor of the current working directory. The
lookup is exact: a path equal to `root` matches, as does a path
nested under `root`; sibling directories with a shared prefix do not.

When two applications' roots nest (e.g., a workspace root with an
application nested inside it), the longest root wins. This lets a
monorepo declare a broad fallback `root` alongside narrower
per-application roots without ambiguity.

If no application's `root` contains the current directory, the
command writes a diagnostic to stderr and exits with a non-zero
status. Manual `bates env <name>` (and peers) always override
resolution and can target any configured application from any
directory.

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
