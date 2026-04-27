# System Overview

Bates is a local development server that runs multiple web applications
simultaneously on macOS. All `*.test` hostnames resolve to localhost via the
macOS resolver. Caddy terminates SSL and reverse-proxies requests to the
correct application. Bates manages application processes and provides a
control interface for visibility and control.

## Domains

### Process Management

The core of the system. Each application defined in the TOML configuration
becomes a supervised OTP process. Processes have a lifecycle (down, starting,
up, crashed) and are assigned dynamically detected ports when they start.
All processes start in the `down` state and are started on demand. After
spawning, a process enters the `starting` state while TCP readiness polling
confirms the application is accepting connections. Middleware transforms
service configuration into process invocations at init time, adding
prologue commands and environment variables.

See [Process Management](process-management.md).

### Routing

Caddy runs as a managed child process. It terminates SSL (via an automatic
local CA), and reverse-proxies requests to application processes based on
hostname. Routes for all configured applications are registered at startup
pointing to the control interface. When an app starts, Bates updates the
route's upstream to the assigned port via the Caddy admin API.

See [Routing](routing.md).

### Control Interface

A dashboard, JSON API, and loading page served on the reserved hostname
`bates.test`. Provides a browser-friendly view of application status,
controls for start/stop/restart, and on-demand startup with boot progress
for applications that aren't running yet.

See [Control Interface](control-interface.md).

## How They Connect

```
*.test → 127.0.0.1          HTTPS request (port 443)
(macOS resolver)                     │
                                     ▼
                            Caddy (managed child process)
                            Terminates SSL, routes by hostname
                                     │
                               ┌─────┴──────┐
                               │            │
                           app.test     app.test
                           (app up)     (app down)
                               │            │
                               ▼            ▼
                           Service      Control Interface
                           (dynamic     starts the app,
                            port)       serves loading page
                               │            │
                               ▼            ▼
                           ProcessSupervisor
                           Manages all configured applications
                               │
                               ▼
                           App (GenServer per application)
                           Manages multiple service lifecycles via erlexec
```

The typical request flow (app running):

1. macOS resolves `myapp.test` to `127.0.0.1` via `/etc/resolver/test`.
2. The client connects to Caddy on port 443.
3. Caddy terminates SSL (certificate issued automatically by its local CA).
4. Caddy matches `myapp.test` to a registered route.
5. Caddy forwards the request to `127.0.0.1:<port>`.
6. The application responds, and Caddy streams the response back.

The on-demand startup flow (app not running):

1. macOS resolves `myapp.test` to `127.0.0.1`.
2. The client connects to Caddy on port 443.
3. Caddy routes to the control interface (the default upstream for
   stopped apps).
4. The control interface starts the app and serves a loading page.
5. The Application GenServer assigns ports to each service via
   `PortNumber.next()`, updates Caddy routes via the admin API, and
   spawns all services. It enters the `starting` state and polls each
   service's port via TCP connect.
6. The loading page (a LiveView) receives boot progress via PubSub.
   When the requested service's readiness check succeeds, the
   Application GenServer broadcasts `up` and the loading page redirects.

### CLI

The command-line interface for launching and interacting with Bates.
`bates start` runs the server in the foreground. Control commands
(`status`, `up`, `down`, `restart`) communicate with the running server
via the JSON API.

See [CLI](cli.md).

## Setup

`bates setup` performs one-time system configuration that requires
elevated permissions:

1. Creates `/etc/resolver/test` to route all `*.test` DNS lookups to
   `127.0.0.1` (requires `sudo`).
2. Runs Caddy's certificate trust step to install the local CA root
   certificate into the macOS system trust store (Caddy prompts for a
   password).

Both steps are idempotent — running `bates setup` again is safe. Bates
should detect when setup hasn't been run and tell the user what to do,
rather than failing silently or elevating automatically.

## Configuration

Applications are defined in a `config.toml` file. Each top-level TOML table
is an application. The table name becomes the application name, which is
used in the control interface and as the default hostname when a service
sets `hostname = true`.

An application can define multiple services, or use a single-command
shorthand:

```toml
[myapp]
root = "~/Code/myapp"

[myapp.services.web]
command = "bin/rails server"
hostname = true

[myapp.services.worker]
command = "bundle exec sidekiq"

[api]
root = "~/Code/api"
command = "bin/server"
```

See [Process Management](process-management.md) for the full configuration
reference.

## Ports

| Port | Service |
|------|---------|
| 443 | Caddy HTTPS (user-facing) |
| 80 | Caddy HTTP (redirects to HTTPS) |
| dynamic | Application processes (internal, not exposed directly) |

## Key Terminology

| Term | Meaning |
|------|---------|
| **Application** | A group of related services that run together, identified by name |
| **Service** | A single OS process within an application (web, worker, etc.) |
| **Application name** | The TOML table name; identifies the application in the control interface and serves as the default hostname |
| **Port number** | Dynamically assigned at app start time, or manually specified in config |
| **Route** | A Caddy routing rule mapping a `.test` hostname to an application port, updated dynamically via the admin API |
| **Fallback** | When an app isn't running, the route points to the control interface. When the app starts, the route is updated to the assigned port with a fallback for 502 errors |
