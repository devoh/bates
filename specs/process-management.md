# Process Management

An application is a group of related services that run together. Each
application defined in the TOML configuration gets one or more OS processes
managed through OTP. Starting an app starts all its services. Stopping an
app stops all its services.

## Applications and Services

An application has:

- A **name** — the TOML table name, doubles as the default hostname prefix.
- A **root** — the working directory for all services.
- One or more **services** — each is an OS process with its own command.

Any service can have a `domain` to make it routable via Caddy. The
application's primary domain (`name.test`) is the default for the first
routable service. Services without a `domain` are companions that don't
serve HTTP.

### Configuration

Multi-service application with a Vite dev server on its own domain:

```toml
[myapp]
root = "~/Code/myapp"

[myapp.services.web]
command = "bin/rails server"
domain = "myapp"

[myapp.services.vite]
command = "bin/vite dev"
domain = "vite.myapp"

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
`domain = "myapp"`.

#### Service fields

| Field | Required | Description |
|-------|----------|-------------|
| `command` | Yes | Shell command to run. |
| `port` | No | `"auto"` to assign the next available port, or a number for a fixed port. Defaults to `"auto"` when `domain` is set. Services with a `port` get the `PORT` environment variable. |
| `domain` | No | Hostname prefix (e.g., `"myapp"` → `myapp.test`). Creates a Caddy route for this service. Implies `port = "auto"` unless overridden. |

#### Application fields

| Field | Required | Description |
|-------|----------|-------------|
| `root` | Yes | Working directory for all services. Supports `~` expansion. |
| `command` | Yes (if no `services`) | Shorthand for a single routable service. |

### Domain and Port Rules

- A service with a `domain` gets `port = "auto"` by default. An explicit
  `port` overrides this.
- A service with a `port` but no `domain` is valid — it gets a port
  assignment but no Caddy route (e.g., a service that listens on a port
  for inter-process communication).
- A service with neither `port` nor `domain` is a plain companion process
  (e.g., a background worker).
- The single-service shorthand implies both `port = "auto"` and
  `domain = "<app-name>"`.

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

Services use `restart: :transient`, meaning OTP only restarts them if they
terminate abnormally. A clean exit or a crash leaves the service stopped
until explicitly restarted.

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

Auto-assigned ports come from a monotonically increasing counter starting
at 4200. Each service with `port = "auto"` gets the next available number.
Services with a numeric `port` use that value directly.

Port assignment happens at application init time, not at startup of the OS
process. A service keeps its assigned port for its entire lifetime, even
across stop/start cycles.

## Supervision

ProcessSupervisor is a DynamicSupervisor. On startup, it reads the TOML
configuration and starts a child for each application. Each application
supervises its own services. Starting children is done asynchronously so
the supervisor can finish initialization without blocking.

All applications are registered in a Registry keyed by application name.
This enables lookup by name from any part of the system (routing, control
interface) without holding direct process references.

## Service Execution

OS processes are managed through `erlexec`, which provides:

- Linked execution (the GenServer is notified on exit).
- stdout/stderr capture (logged via Elixir's Logger with the application
  and service name as a prefix).
- Signal-based stop (graceful shutdown).
- Working directory configuration (from the application's `root`).

## How It Connects

- **Routing** generates a Caddy route for every service that has a `domain`.
  Each route maps `<domain>.test` to the service's port with a fallback to
  the control interface. Routes are static — routing does not interact with
  process lifecycle.
- **Control interface** starts and stops entire applications (all services
  together). It is also the fallback upstream for Caddy routes, triggering
  on-demand startup when a request arrives for a down app. The loading page
  waits for the specific service that was requested to accept connections.
