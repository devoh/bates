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

Each service has three states:

| State | Meaning |
|-------|---------|
| **down** | Registered but not running. No OS process exists. |
| **up** | Running. An OS process is alive and linked. |
| **crashed** | The OS process exited with a non-zero status. |

Transitions:

- `down` → `up`: The `up` command starts the OS process via `erlexec`.
- `up` → `down`: The `down` command sends a stop signal via `erlexec`.
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

Starting an app starts all its services. Stopping an app stops all its
services. The on-demand startup flow (via Caddy fallback) starts the full
application, not just the triggered service.

## Port Assignment

Auto-assigned ports are detected dynamically by binding a TCP socket to
port 0, reading the OS-assigned port, and closing the socket. This
guarantees the port is available at assignment time. Services with a
numeric `port` use that value directly.

Port assignment happens at application init time, not at startup of the OS
process. A service keeps its assigned port for its entire lifetime, even
across stop/start cycles. Ports may differ across Conjure restarts since
they are dynamically assigned rather than deterministic.

## Supervision

ProcessSupervisor is a DynamicSupervisor. On startup, it reads the TOML
configuration and starts a child for each application. Each application
supervises its own services. Starting children is done asynchronously so
the supervisor can finish initialization without blocking.

All applications are registered in a Registry keyed by application name.
This enables lookup by name from any part of the system (routing, control
interface) without holding direct process references.

## Middleware

Middleware transforms service configuration into a process invocation at
init time. Each middleware can add entries to the process invocation's
`prologue` (shell commands) and `environment` (variables).

Middleware can be specified at two levels:

- **Application-level** — applies to all services in the application.
  Runs first. Use for project-wide concerns like runtime version
  managers.
- **Service-level** — applies to a single service. Runs after
  application-level middleware. Use for service-specific concerns like
  port assignment.

```toml
[myapp]
root = "~/Code/myapp"
middleware = ["asdf"]

[myapp.services.web]
command = "bin/rails server"
hostname = true
middleware = ["port"]

[myapp.services.worker]
command = "bundle exec sidekiq"
```

In this example, the web service's pipeline is `asdf` then `port`. The
worker has only `asdf` — no port assignment since it doesn't serve HTTP.

Middleware ordering is the user's responsibility; if middleware B depends
on a runtime managed by middleware A, list A first.

### Process Invocation

The process invocation is the runtime structure built from configuration
and middleware. It is not something the user writes directly — it is
assembled at init time.

| Field | Source | Description |
|-------|--------|-------------|
| `prologue` | Middleware | Ordered list of shell commands that run before `command` to set up the environment. |
| `environment` | Config + middleware | Map of environment variables set before the prologue runs. |
| `command` | Config | The supervised process. Copied from the service's `command` field. |

### Built-in Middleware

| Middleware | What it does |
|------------|-------------|
| `asdf` | Adds `source $(brew --prefix)/opt/asdf/libexec/asdf.sh` to the prologue, enabling asdf-managed runtimes. |
| `port` | Assigns a dynamically detected port to the `PORT` environment variable for services with a `port` (explicit or implied by `hostname`). |

## Service Execution

Each service is executed in a single shell context using its process
invocation. The `environment` variables are exported first, `prologue`
commands run in order to build up the shell environment (PATH, shims,
etc.), and the `command` runs as the final step, inheriting everything.

Conceptually, the execution is equivalent to:

```bash
# Environment (from config and middleware)
export PORT=<assigned-port>

# Prologue (from middleware, in order)
source /opt/homebrew/opt/asdf/libexec/asdf.sh

# Command (the supervised process)
exec bin/rails server
```

OS processes are managed through `erlexec`, which provides:

- Linked execution (the GenServer is notified on exit).
- stdout/stderr capture.
- Signal-based stop (graceful shutdown).
- Working directory configuration (from the application's `root`).

## Readiness

A service with a port is considered ready when a TCP connection to its
assigned port succeeds. Conjure polls the port after starting the service.
This is used by the on-demand startup flow — the control interface's
loading page waits for the TCP check to pass before redirecting.

Services without a port have no readiness check. They are considered ready
immediately after the OS process starts.

## Logging

Each service's stdout and stderr are captured and handled in two ways:

1. **Interleaved stream.** All service output is written to Conjure's
   stdout with each line prefixed by the application and service name
   (e.g., `[myapp:web]`). This provides a single stream for watching
   all activity.

2. **Per-service log files.** Each service's output is also written to a
   dedicated log file for isolated inspection. Log files are stored in a
   runtime directory scoped to the current Conjure session.

## How It Connects

- **Routing** generates a Caddy route for every service that has a `hostname`.
  Each route maps `<hostname>.test` to the service's port with a fallback to
  the control interface. Routes are static — routing does not interact with
  process lifecycle.
- **Control interface** starts and stops entire applications (all services
  together). It is also the fallback upstream for Caddy routes, triggering
  on-demand startup when a request arrives for a down app. The loading page
  waits for the specific service that was requested to accept connections.
