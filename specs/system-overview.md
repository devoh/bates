# System Overview

Conjure is a local development server that runs multiple web applications
simultaneously on macOS. All `*.test` hostnames resolve to localhost via the
macOS resolver. Caddy terminates SSL and reverse-proxies requests to the
correct application. Conjure manages application processes and provides a
control interface for visibility and control.

## Domains

### Process Management

The core of the system. Each application defined in the TOML configuration
becomes a supervised OTP process. Processes have a lifecycle (down, up,
crashed) and are assigned unique ports from a monotonically increasing
counter starting at 4200. All processes start in the `down` state and are
started on demand.

See [Process Management](process-management.md).

### Routing

Caddy runs as a managed child process. It terminates SSL (via an automatic
local CA), and reverse-proxies requests to application processes based on
hostname. Routes for all configured applications are registered at startup
with a fallback to the control interface for apps that aren't running.

See [Routing](routing.md).

### Control Interface

A dashboard, JSON API, and loading page served on the reserved hostname
`conjure.test`. Provides a browser-friendly view of application status,
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
                           Application  Control Interface
                           process      starts the app,
                           (port 4200+) serves loading page
                               │            │
                               ▼            ▼
                           ProcessSupervisor
                           Manages all configured processes
                               │
                               ▼
                           Process (GenServer per app)
                           Manages OS process lifecycle via erlexec
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
3. Caddy tries the primary upstream — connection refused (app is down).
4. Caddy falls back to the control interface.
5. The control interface starts the app and serves a loading page.
6. The loading page polls for readiness and redirects when the app is up.

## Setup

`conjure setup` performs one-time system configuration that requires
elevated permissions:

1. Creates `/etc/resolver/test` to route all `*.test` DNS lookups to
   `127.0.0.1` (requires `sudo`).
2. Runs Caddy's certificate trust step to install the local CA root
   certificate into the macOS system trust store (Caddy prompts for a
   password).

Both steps are idempotent — running `conjure setup` again is safe. Conjure
should detect when setup hasn't been run and tell the user what to do,
rather than failing silently or elevating automatically.

## Configuration

Applications are defined in a `config.toml` file. Each top-level TOML table
is an application. The table name becomes the application name (and thus the
hostname: `name.test`).

An application can define multiple services, or use a single-command
shorthand:

```toml
[myapp]
root = "~/Code/myapp"

[myapp.services.web]
command = "bin/rails server"

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
| 4200+ | Application processes (internal, not exposed directly) |

## Key Terminology

| Term | Meaning |
|------|---------|
| **Application** | A group of related services that run together, identified by name |
| **Service** | A single OS process within an application (web, worker, etc.) |
| **Application name** | The TOML table name; doubles as the hostname prefix (`name` → `name.test`) |
| **Port number** | Auto-assigned starting at 4200, or manually specified in config |
| **Route** | A Caddy routing rule mapping a `.test` hostname to an application port with a fallback |
| **Fallback** | When an app isn't running, Caddy routes the request to the control interface instead |
