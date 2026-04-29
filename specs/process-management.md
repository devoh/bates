# Process Management

An application is a group of related services that run together. Each
application defined in the TOML configuration gets one or more OS processes
managed through OTP. Starting an app starts all its services. Stopping an
app stops all its services.

## Applications and Services

An application has:

- A **name** — the TOML table name, used to identify the application in
  the control interface and as the default hostname when a service sets
  `hostname = true`.
- A **root** — the working directory for all services.
- One or more **services** — each is an OS process with its own command.

Any service can have a `hostname` to make it routable via Caddy. Services
without a `hostname` are companions that don't serve HTTP.

### Configuration

Multi-service application with a Vite dev server on its own hostname:

```toml
[myapp]
root = "~/Code/myapp"

[myapp.services.web]
command = "bin/rails server"
hostname = true

[myapp.services.vite]
command = "bin/vite dev"
hostname = "vite.myapp"

[myapp.services.worker]
command = "bundle exec sidekiq"
```

Single-service shorthand — when an app has only one service, `command` can
be specified directly on the application table:

```toml
[myapp]
root = "~/Code/myapp"
command = "bin/rails server"
```

This is equivalent to defining a single service with `port = "auto"` and
`hostname = true`.

#### Application fields

| Field | Required | Description |
|-------|----------|-------------|
| `root` | Yes | Working directory for all services. Supports `~` expansion. |
| `command` | Yes (if no `services`) | Shorthand for a single routable service. |
| `middleware` | No | Ordered list of middleware names. Applied to all services in this application at init time. |

#### Service fields

| Field | Required | Description |
|-------|----------|-------------|
| `command` | Yes | Shell command to run (the supervised process). |
| `port` | No | `"auto"` to assign a dynamically detected port, or a number for a fixed port. Defaults to `"auto"` when `hostname` is set. |
| `hostname` | No | `true` to use the application name as the hostname (e.g., `myapp` → `myapp.test`), or a string for a custom hostname (e.g., `"vite.myapp"` → `vite.myapp.test`). Creates a Caddy route. Implies `port = "auto"` unless overridden. |
| `middleware` | No | Ordered list of middleware names. Applied after the application-level middleware. |
| `depends_on` | No | List of sibling service names in the same application that must be `up` before this service starts. |

### Hostname and Port Rules

- A service with a `hostname` gets `port = "auto"` by default. An explicit
  `port` overrides this.
- A service with a `port` but no `hostname` is valid — it gets a port
  assignment but no Caddy route (e.g., a service that listens on a port
  for inter-process communication).
- A service with neither `port` nor `hostname` is a plain companion process
  (e.g., a background worker).
- The single-service shorthand implies both `port = "auto"` and
  `hostname = true`.

## Service Lifecycle

Each service has four states:

| State | Meaning |
|-------|---------|
| **down** | Registered but not running. No OS process exists. |
| **starting** | OS process spawned but not yet accepting connections. TCP readiness polling is in progress. |
| **up** | Running and ready. The OS process is alive and accepting TCP connections on its assigned port. |
| **crashed** | The OS process exited with a non-zero status, or the readiness check timed out. |

Transitions:

- `down` → `starting`: The `up` command spawns the OS process once every service in `depends_on` is `up`.
- `starting` → `up`: The TCP readiness check succeeds (port accepts connections).
- `starting` → `crashed`: The readiness check times out (60 seconds) or the OS process exits during startup.
- `starting` → `down`: The `down` command stops the OS process during startup.
- `up` → `down`: The `down` command sends a stop signal.
- `up` → `down`: The OS process exits cleanly (status 0).
- `up` → `crashed`: The OS process exits with a non-zero status.
- Calling `up` on an already-running service is a no-op.
- Calling `down` on an already-stopped service is a no-op.

Services do not restart automatically. A crash or clean exit leaves the
service stopped until explicitly restarted. This is intentional for a
development server — a crash is a signal to the developer, not something
to paper over with automatic restarts.

## Application Lifecycle

An application's status is derived from its services:

| Condition | App status |
|-----------|-----------|
| All services up | **up** |
| All services down | **down** |
| Any service crashed | **crashed** |
| Otherwise | **partial** |

Starting an app walks the service dependency graph: services with no
unmet dependencies start in parallel; the rest start as their
dependencies become `up`. Stopping an app reverses the order —
dependents stop before their dependencies. The on-demand startup flow
(via Caddy fallback) still triggers the full application, not just the
requested service; the loading page subscribes to the specific service
that was requested and redirects when that service is `up`, regardless
of where it sits in the graph.

## Service Dependencies

A service's `depends_on` field lists sibling services within the same
application that must reach `up` before this service is started. While
any dependency is not yet `up`, the service stays in `down`.

```toml
[myapp.services.web]
command = "bin/rails server"
hostname = true
depends_on = ["vite"]

[myapp.services.vite]
command = "bin/vite dev"
hostname = "vite.myapp"
```

Cross-application dependencies are not supported; `depends_on` may only
name services declared in the same application table.

Validation runs at configuration load time. Bates refuses to start when
a `depends_on` entry names a service that does not exist in the same
application, or when the dependency graph contains a cycle. The error
is surfaced by the configuration loader before any application is
supervised.

If a dependency reaches `crashed` instead of `up`, its dependents
remain in `down`. The application status derivation already covers
this case: any service `crashed` makes the application `crashed`.

The 60-second readiness timeout begins when a service enters
`starting`. Time spent waiting for dependencies in `down` does not
count against this budget — a slow dependency cannot cause its
dependents to time out before they have a chance to run.

## Port Assignment

Auto-assigned ports are detected dynamically by binding a TCP socket to
port 0, reading the OS-assigned port, and closing the socket. This
guarantees the port is available at assignment time. Services with a
numeric `port` in the configuration use that value directly.

Port assignment happens in `App.up/1` when a service starts, not at
configuration time. The assigned port is stored in an `assigned_port`
field in the GenServer's service state, separate from `config.port`
(which holds the declared value: `nil` for auto-assigned, integer for
static). On stop, the assigned port is released (`assigned_port` set
back to `nil`). Each start cycle gets a fresh port assignment. Ports
may differ not only across Bates restarts but also across stop/start
cycles within a single session.

## Supervision

On startup, Bates reads the TOML configuration and creates a
supervised process for each application. Each application supervises
its own services. Applications start asynchronously so initialization
doesn't block.

Applications are registered by name, enabling lookup from any part of
the system (routing, control interface) without direct process
references.

## Middleware

Middleware transforms service configuration into a process invocation at
init time. Each middleware can add entries to the process invocation's
`prologue` (shell commands) and `environment` (variables).

Middleware can be specified at two levels:

- **Application-level** — applies to all services in the application.
  Runs first. Use for project-wide concerns like runtime version
  managers.
- **Service-level** — applies to a single service. Runs after
  application-level middleware. Use for service-specific concerns.

```toml
[myapp]
root = "~/Code/myapp"
middleware = ["asdf"]

[myapp.services.web]
command = "bin/rails server"
hostname = true

[myapp.services.worker]
command = "bundle exec sidekiq"
```

In this example, the web service runs `asdf` and then `port` (the
`port` middleware is applied automatically by Bates because the service
has a hostname — users do not list it). The worker runs only `asdf`,
since it does not serve HTTP and gets no port assignment.

Middleware ordering is the user's responsibility; if middleware B depends
on a runtime managed by middleware A, list A first.

The application-level and service-level lists are merged at config
parse time into a single ordered list per service. The runtime sees
only that merged list. Unknown middleware names cause Bates to refuse
to start; the error is surfaced by the configuration loader before any
application is supervised.

### Process Invocation

The process invocation is the runtime structure built from configuration
and middleware. It is not something the user writes directly — it is
assembled at init time.

| Field | Source | Description |
|-------|--------|-------------|
| `prologue` | Middleware | Ordered list of shell commands that run before `command` to set up the environment. |
| `environment` | Config + middleware | Map of environment variables set on the OS process by the spawner (not via shell `export`). |
| `command` | Config | The supervised process. Copied from the service's `command` field. |

### Built-in Middleware

| Middleware | What it does |
|------------|-------------|
| `asdf` | Adds `source $(brew --prefix)/opt/asdf/libexec/asdf.sh` to the prologue, enabling asdf-managed runtimes. |
| `direnv` | Adds `eval "$(direnv export bash)"` to the prologue, loading the working directory's `.envrc` into the environment. |
| `port` | Sets the `PORT` environment variable to the service's assigned port. Applied automatically for services with a hostname; users do not need to list it. |

## Service Execution

Each service is executed in a single shell invocation built from its
process invocation. Environment variables come from the OS process
spawner (erlexec's `env:` option, which merges with Bates's inherited
environment so `PATH`, `HOME`, etc. survive); they are not exported by
shell. The prologue commands run in order to build up the shell
environment (PATH, shims, etc.), and the supervised command runs as
the final step, prefixed with `exec` so that signals reach it
directly without an intermediate shell.

The compiled invocation has the form:

```
prologue1; prologue2; exec <command>
```

When the prologue is empty, the result is simply `exec <command>`.

Conceptually, the execution is equivalent to:

```bash
# Environment (set on the OS process by the spawner)
PORT=<assigned-port>

# Prologue + exec'd command (single shell invocation)
source /opt/homebrew/opt/asdf/libexec/asdf.sh; exec bin/rails server
```

OS processes require:

- Linked execution (Bates is notified on exit).
- stdout/stderr capture.
- Signal-based stop (graceful shutdown).
- Working directory configuration (from the application's `root`).

## Readiness

After spawning the OS process, Bates polls `127.0.0.1:<port>` via TCP
connect every 200ms. When the connection succeeds, the service transitions
from `starting` to `up` and a PubSub broadcast fires. If 60 seconds elapse
without a successful connection, the OS process is stopped and the service
transitions to `crashed` with a timeout message.

The loading page subscribes to PubSub and redirects only when it receives
the `up` broadcast, ensuring the application is actually accepting
connections before the user is sent there.

Services without a port have no readiness check. They are considered ready
immediately after the OS process starts (transition directly from `starting`
to `up` with no polling).

## Logging

Each service's stdout and stderr are captured and handled in two ways:

1. **Interleaved stream.** All service output is written to Bates's
   stdout with each line prefixed by the application and service name
   (e.g., `[myapp:web]`). This provides a single stream for watching
   all activity.

2. **Per-service ring buffer.** Each service keeps its recent output in
   an in-memory ring buffer. This provides isolated, per-service access
   to recent log output without writing to disk. The buffer is used by
   the loading page to display crash output, and can be exposed via the
   API for CLI access (e.g., `bates logs myapp:web`). Logs are lost on
   Bates restart, which is acceptable for a development server.

## How It Connects

- **Routing** generates a Caddy route for every service that has a `hostname`.
  All routes initially point to the control interface. When a service starts
  and gets a port, `App.up/1` calls `Caddy.update_route/2` to update the
  route's upstream to the assigned port. When a service stops, `App.down/1`
  calls `Caddy.revert_route/1` to point the route back to the control
  interface.
- **Control interface** starts and stops entire applications (all services
  together). It is also the fallback upstream for Caddy routes, triggering
  on-demand startup when a request arrives for a down app. The loading page
  waits for the specific service that was requested to accept connections.
