# Control Interface

A built-in dashboard, API, and loading page served by Conjure on its own
internal port. Caddy routes `conjure.test` directly here, and all application
routes fall back here when the app isn't running.

## Dashboard

A human-friendly web page at `conjure.test` that shows the state of all
configured applications. The dashboard is the default view when visiting
`conjure.test` in a browser.

Implemented as a Phoenix LiveView. The LiveView subscribes to process
state changes via PubSub, so the dashboard updates in real time without
polling or client-side JavaScript.

### What It Shows

For each application:

- **Name** — the process name from the TOML configuration.
- **Hostname** — the `.test` URL (clickable link to the app).
- **Status** — up, down, or crashed. Updates live as state changes.
- **Port** — the assigned port number.

### Controls

Each application has controls to:

- **Start** — boot the application process.
- **Stop** — gracefully shut down the application process.
- **Restart** — stop then start.

Controls should reflect current state: a running app shows stop and restart,
a stopped app shows start, a crashed app shows start. Controls update
immediately as state transitions occur.

## Loading Page

When a request arrives for an application that isn't running, Caddy's
fallback routes it here. The control interface identifies the target app
from the request's `Host` header.

Implemented as a Phoenix LiveView. The LiveView subscribes to the
target process's state changes via PubSub, providing real-time boot
progress without polling.

The flow:

1. Triggers `Process.up/1` to start the application.
2. Shows the app name and boot status, updating live as the process
   starts.
3. On ready (TCP port accepts connections): redirects to the original URL.
4. On crash: displays the error with recent log output.

### Crash Display

If the process exits during boot (non-zero exit status), the loading page
shows:

- The process name and status (crashed).
- The exit status code.
- Recent log output (stdout/stderr captured by the process GenServer).

This gives the developer immediate feedback without needing to check a
terminal.

## API

A JSON API on `conjure.test` for programmatic control. This is what a CLI
tool (`conjure status`, `conjure up myapp`) would use under the hood.

### Endpoints

**List all processes and their status:**

```
GET conjure.test/status

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
POST conjure.test/processes/<name>/start

→ 200  {"name": "myapp", "status": "up"}
→ 422  {"name": "myapp", "error": "..."}
```

**Stop a process:**

```
POST conjure.test/processes/<name>/stop

→ 200  {"name": "myapp", "status": "down"}
→ 422  {"name": "myapp", "error": "..."}
```

**Restart a process:**

```
POST conjure.test/processes/<name>/restart

→ 200  {"name": "myapp", "status": "up"}
→ 422  {"name": "myapp", "error": "..."}
```

### Content Negotiation

The dashboard and API share the same hostname. Routing between them:

- Browser requests (`Accept: text/html`) get the dashboard.
- JSON requests (`Accept: application/json`) or explicit `.json` paths get
  the API.

## How It Connects

Caddy routes requests to `conjure.test` directly to the control interface.
All application routes use the control interface as a fallback upstream —
when an app isn't listening, Caddy's connection is refused and the request
lands here instead. See [Routing](routing.md).

The control interface delegates to the process management layer:
`Process.up/1`, `Process.down/1`, `ProcessSupervisor.status/0`. It reads
process log output for crash display.

Both the dashboard and loading page are LiveViews that subscribe to
process state changes via Phoenix PubSub. Process GenServers broadcast
state transitions (down → up, up → crashed, etc.), and connected
LiveViews receive those events and re-render immediately.
