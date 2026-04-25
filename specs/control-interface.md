# Control Interface

A built-in dashboard, API, and loading page served by Bates on its own
internal port. Caddy routes `bates.test` directly here, and all application
routes fall back here when the app isn't running.

## Dashboard

A human-friendly web page at `bates.test` that shows the state of all
configured applications. The dashboard is the default view when visiting
`bates.test` in a browser.

Implemented as a Phoenix LiveView. The LiveView subscribes to process
state changes via PubSub, so the dashboard updates in real time without
polling or client-side JavaScript.

### What It Shows

For each application:

- **Name** — the process name from the TOML configuration.
- **Hostname** — the `.test` URL (clickable link to the app).
- **Status** — down, starting, up, or crashed. Updates live as state changes.
- **Port** — the assigned port number.

### Controls

Each application has controls to:

- **Start** — boot the application process.
- **Stop** — gracefully shut down the application process.
- **Restart** — stop then start.

Controls should reflect current state: a running app shows stop and restart,
a starting app shows stop, a stopped app shows start, a crashed app shows
start. Controls update immediately as state transitions occur.

## Loading Page

When a request arrives for an application that isn't running, Caddy's
fallback routes it here. The control interface identifies the target app
from the request's `Host` header.

Implemented as a Phoenix LiveView. The LiveView subscribes to the
target process's state changes via PubSub, providing real-time boot
progress without polling.

The flow:

1. Subscribes to PubSub for the target process, then triggers
   `Process.up/1` to start the application.
2. Checks the process status. If already `up` (TCP readiness check has
   passed), redirects immediately without waiting for a PubSub message.
3. Otherwise, shows the app name and boot status (typically `starting`),
   updating live as the process starts.
4. The process GenServer polls the assigned port via TCP connect. When
   the connection succeeds, it broadcasts `{:status, "up"}` via PubSub.
5. On receiving `{:status, "up"}`: redirects to the original URL.
6. On crash or readiness timeout: displays the error with recent log
   output.

### Crash Display

If the process exits during boot (non-zero exit status), the loading page
shows:

- The process name and status (crashed).
- The exit status code.
- Recent log output (stdout/stderr captured by the process GenServer).

This gives the developer immediate feedback without needing to check a
terminal.

## API

A JSON API on `bates.test` for programmatic control. This is what a CLI
tool (`bates status`, `bates up myapp`) would use under the hood.

### Endpoints

**List all processes and their status:**

```
GET bates.test/status

→ 200
{
  "processes": [
    {"name": "myapp", "hostname": "myapp.test", "status": "up", "port": 4200},
    {"name": "api", "hostname": "api.test", "status": "down", "port": 4201}
  ]
}
```

**Start a process:**

```
POST bates.test/processes/<name>/start

→ 200  {"name": "myapp", "status": "up"}
→ 422  {"name": "myapp", "error": "..."}
```

**Stop a process:**

```
POST bates.test/processes/<name>/stop

→ 200  {"name": "myapp", "status": "down"}
→ 422  {"name": "myapp", "error": "..."}
```

**Restart a process:**

```
POST bates.test/processes/<name>/restart

→ 200  {"name": "myapp", "status": "up"}
→ 422  {"name": "myapp", "error": "..."}
```

### Content Negotiation

The dashboard and API share the same hostname. Routing between them:

- Browser requests (`Accept: text/html`) get the dashboard.
- JSON requests (`Accept: application/json`) or explicit `.json` paths get
  the API.

## How It Connects

Caddy routes requests to `bates.test` directly to the control interface.
All application routes use the control interface as a fallback upstream —
when an app isn't listening, Caddy's connection is refused and the request
lands here instead. See [Routing](routing.md).

An `AppRedirect` plug in the browser pipeline intercepts app-domain
requests (any `.test` hostname other than `bates.test`) and redirects
them to the loading page before they reach any route. This keeps the
dashboard and other control-domain routes from accidentally handling
app-domain traffic.

The control interface delegates to the process management layer for
starting, stopping, and querying application state. It reads process
log output for crash display.

Both the dashboard and loading page are LiveViews that subscribe to
process state changes via PubSub. Application processes broadcast
state transitions (down → up, up → crashed, etc.), and connected
LiveViews receive those events and re-render immediately.
