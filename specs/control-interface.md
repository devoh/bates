# Control Interface

A built-in dashboard, API, and loading page served by Bates on its own
internal port. Caddy routes `bates.test` directly here, and all application
routes fall back here when the app isn't running.

## Dashboard

A human-friendly web page at `bates.test` that shows the state of all
configured applications. The dashboard is the default view when visiting
`bates.test` in a browser.

Implemented as a Phoenix LiveView. The LiveView subscribes to
application-level state changes via PubSub (`"app:<name>"`), so the
dashboard updates in real time without polling or client-side JavaScript.

### What It Shows

For each application:

- **Name** — the application name from the TOML configuration.
- **Hostname** — the `.test` URL (clickable link to the app).
- **Status** — down, starting, up, crashed, or partial. Updates live as
  state changes. Status is derived from the application's services (see
  [Process Management](process-management.md)).
- **Port** — the assigned port number (for single-service apps).

Multi-service applications show nested service rows beneath the
application row. Each service row shows the service name, hostname (if
routable), status, and port. Single-service apps show only the
application row with no nesting.

### Controls

Each application has controls to:

- **Start** — boot all services in the application.
- **Stop** — gracefully shut down all services.
- **Restart** — stop then start all services.

Controls reflect current state: a running app shows stop and restart,
a starting app shows stop, a stopped app shows start, a crashed app
shows start, a partial app shows start, stop, and restart. Controls
are application-level only — there are no per-service controls.

## Loading Page

When a request arrives for an application that isn't running, Caddy's
fallback routes it here. The control interface identifies the target app
from the request's `Host` header via a hostname-to-application lookup.

Implemented as a Phoenix LiveView. When a specific service hostname was
requested (e.g., `vite.myapp.test`), the LiveView subscribes to that
service's PubSub topic (`"service:<app>:<service>"`). Otherwise it
subscribes to the application-level topic (`"app:<app>"`).

The flow:

1. Subscribes to PubSub for the target (service or application), then
   triggers `App.up/1` to start the full application (all services).
2. Checks the application status. If already `up`, redirects immediately
   without waiting for a PubSub message.
3. Otherwise, shows the app name and boot status (typically `starting`),
   updating live as the application starts.
4. The Application GenServer polls each service's assigned port via TCP
   connect. When a service's connection succeeds, it broadcasts
   `{:status, "up"}` on both the service and application PubSub topics.
5. On receiving `{:status, "up"}` for the subscribed target: redirects
   to the originally requested hostname (e.g., `https://vite.myapp.test`),
   not necessarily the application's default hostname. The loading page
   does not wait for all services to be up — only the requested one.
6. On crash or readiness timeout: displays the error with recent log
   output.

### Crash Display

If a service exits during boot (non-zero exit status), the loading page
shows:

- The application name and status (crashed).
- The exit status code.
- Recent log output (stdout/stderr captured by the Application GenServer).

This gives the developer immediate feedback without needing to check a
terminal.

## API

A JSON API on `bates.test` for programmatic control. This is what a CLI
tool (`bates status`, `bates up myapp`) would use under the hood.

### Endpoints

**List all applications and their status:**

```
GET bates.test/status

→ 200
{
  "processes": [
    {
      "name": "myapp",
      "status": "up",
      "services": [
        {"name": "web", "hostname": "myapp.test", "status": "up", "port": 52341},
        {"name": "worker", "hostname": null, "status": "up", "port": null}
      ]
    },
    {
      "name": "api",
      "status": "down",
      "services": [
        {"name": "api", "hostname": "api.test", "status": "down", "port": 52342}
      ]
    }
  ]
}
```

**Start an application:**

```
POST bates.test/processes/<name>/start

→ 200  {"name": "myapp", "status": "up"}
→ 422  {"name": "myapp", "error": "..."}
```

**Stop an application:**

```
POST bates.test/processes/<name>/stop

→ 200  {"name": "myapp", "status": "down"}
→ 422  {"name": "myapp", "error": "..."}
```

**Restart an application:**

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
them to the loading page before they reach any route. The plug uses a
hostname-to-application lookup to resolve arbitrary hostnames (e.g.,
`vite.myapp.test` → application `myapp`) rather than parsing the
hostname string. When a non-default hostname is requested, it is passed
as a query parameter so the loading page knows which service to wait
for. This keeps the dashboard and other control-domain routes from
accidentally handling app-domain traffic.

The control interface delegates to the process management layer for
starting, stopping, and querying application state. It reads service
log output for crash display.

Both the dashboard and loading page are LiveViews that subscribe to
state changes via PubSub. Application GenServers broadcast state
transitions at both the service level (`"service:<app>:<service>"`)
and application level (`"app:<app>"`). Connected LiveViews receive
those events and re-render immediately.
