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

Each application has application-level controls to:

- **Start all** — boot all services in the application.
- **Stop all** — gracefully shut down all services.
- **Restart** — stop then start all services.

Application-level controls reflect current state: a running app shows
stop and restart, a starting app shows stop, a stopped app shows
start, a crashed app shows start, a partial app shows start, stop,
and restart.

Multi-service applications additionally render per-service **Start**
and **Stop** buttons on each service row. Single-service applications
do not render per-service controls (the application-level controls
already cover the same operations). The per-service buttons reflect
the service's current state: Start is disabled when the service is
`up` or `starting`; Stop is disabled when the service is `down`.

Per-service stop cascades through the service's dependents (every
service that transitively `depends_on` the target stops too, in
reverse-topological order). Per-service start auto-walks the
service's dependency closure forward (every service the target
transitively `depends_on` starts first, then the target itself once
its dependencies are `up`). There is no per-service Restart control
— stop-then-start is structurally avoided to keep exports consistent
across the dependency graph.

Any user-initiated stop (application-level or per-service) marks the
application as **paused** until an explicit user-initiated start
clears it. The loading page intercepts on-demand startup for paused
applications (see Loading Page below).

## Loading Page

When a request arrives for an application that isn't running, Caddy's
fallback routes it to the control interface. An `AppRedirect` plug
identifies the target app and service from the request's `Host` header
via a hostname-to-application lookup and redirects to the loading page
on the control host (`bates.test`).

The loading page is a blocking controller action at
`/loading/:app_name/:service_name`. It works for all HTTP clients
(browsers, curl, API clients) without requiring a websocket.

The flow:

1. Subscribes to PubSub for the target service
   (`"service:<app>:<service>"`), then triggers `App.up/1` to start the
   full application (all services).
2. Checks the application status. If already `up`, redirects immediately.
3. Otherwise, blocks until the service comes up, waiting in a receive
   loop for the PubSub broadcast.
4. The Application GenServer polls each service's assigned port via TCP
   connect. When a service's connection succeeds, it broadcasts
   `{:status, "up"}` on both the service and application PubSub topics.
5. On receiving `{:status, "up"}`: redirects to the service's hostname
   (e.g., `https://vite.myapp.test`). The loading page does not wait for
   all services to be up — only the requested one.
6. On crash: returns 502 with the application name and error details.
7. On readiness timeout: returns 504.

Because the loading page is served from `bates.test` (the control host),
its connection is not disrupted when Caddy updates the app's route
upstream on startup.

### Paused Apps

When an application is paused (any user-initiated stop has occurred
and no user-initiated start has cleared it since), the loading page
does NOT run the blocking start flow. Instead:

- **Browsers** see a static **paused page** (a LiveView) listing the
  application's services with current status lamps and a **Resume**
  button. Resume re-issues the same request with `?resume=true`,
  which falls through to the normal loading flow. The normal flow's
  `App.up/1` call clears the paused flag and the browser lands on
  the application as usual.
- **Non-HTML clients** (curl, HTTP libraries, anything whose
  `Accept` header excludes `text/html`) receive a **503** response
  with a JSON body of the form
  `{"app": "<name>", "status": "paused", "reason": "..."}`. The
  body's `reason` points the caller at `bates.test` and the
  `bates up <app>` CLI command.

This is the mechanism that makes per-service stop useful: without
paused, a browser tab polling `myapp.test` would silently re-start
the service the user just stopped. With paused, on-demand startup
defers to the user.

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

→ 200
{
  "name": "myapp",
  "status": "up",
  "exports": {
    "PGHOST": "127.0.0.1",
    "PGPORT": "52345"
  }
}
→ 422  {"name": "myapp", "status": "crashed", "reason": "..."}
→ 504  {"name": "myapp", "status": "timeout", "reason": "..."}
→ 404  {"name": "myapp", "status": "unknown", "reason": "..."}
```

Blocks until the application's services have either spawned (and
produced their exports) or terminal-failed, up to a 60-second
readiness timeout. When the app is already `up`, returns
immediately. Concurrent callers against a `down` app each receive
the same merged exports without duplicate spawns.

The `status` field reflects the application's actual derived
status at response time. For port-bearing services this can be
`starting` (services have spawned and exports are populated, but
the TCP port is not yet bound) — exports are still valid and
intended to be consumed; readiness is the caller's concern.

**Stop an application:**

```
POST bates.test/processes/<name>/stop

→ 200  {"name": "myapp", "status": "down"}
→ 422  {"name": "myapp", "error": "..."}
```

Stopping an application also marks it as **paused** so the loading
page intercepts on-demand startup until a user-initiated start
clears the flag. This is a behavior change vs. an earlier API where
stop was purely transactional.

**Restart an application:**

```
POST bates.test/processes/<name>/restart

→ 200  {"name": "myapp", "status": "up"}
→ 422  {"name": "myapp", "error": "..."}
```

Restart has no per-service form. Stale environment exports propagate
through restarts, so per-service restart is structurally omitted in
favor of explicit `stop`/`start` pairs.

**Start a service within an application:**

```
POST bates.test/processes/<app>/services/<service>/start

→ 200
{
  "app": "myapp",
  "service": "web",
  "status": "up",
  "port": 52341,
  "hostname": "myapp.test"
}
→ 422  {"app": "myapp", "service": "web", "status": "crashed", "reason": "..."}
→ 504  {"app": "myapp", "service": "web", "status": "timeout", "reason": "..."}
→ 404  {"app": "myapp", "service": "web", "status": "unknown", "reason": "..."}
```

Auto-walks the service's dependency closure forward. Blocks until
the named service settles to `up`, broadcasts `crashed`, or the
readiness timeout fires. The 200 response is status-only (no
`exports` field); callers that need merged application exports use
the application-level start endpoint.

A user-initiated per-service start clears the application's paused
flag.

**Stop a service within an application:**

```
POST bates.test/processes/<app>/services/<service>/stop

→ 200
{
  "app": "myapp",
  "service": "postgresql",
  "status": "down",
  "cascaded": [
    {"service": "web", "status": "down"},
    {"service": "worker", "status": "down"}
  ]
}
→ 422  {"app": "myapp", "service": "postgresql", "error": "..."}
→ 404  {"app": "myapp", "service": "missing", "status": "unknown", "reason": "..."}
```

Cascades through the service's dependents in reverse-topological
order and returns the additionally stopped services in the
`cascaded` array (the target itself is NOT repeated in the array).
The order matches the broadcast order: outermost dependent first.
For a leaf service, `cascaded` is `[]`.

A user-initiated per-service stop marks the application as paused.

**Application exports** (e.g., `PGHOST`, `PGPORT` from the
`postgresql` addon) are returned as part of the
`POST /processes/<name>/start` response. There is no separate env
endpoint. If two services export the same key, last-writer-wins by
service start order.

**Get application logs:**

```
GET bates.test/processes/<name>/logs

→ 200
{
  "name": "myapp",
  "services": [
    {"name": "web", "lines": ["Starting server on port 3000...", "Listening..."]},
    {"name": "worker", "lines": ["Worker started", "Processing jobs..."]}
  ]
}
```

Returns the recent output from each service's in-memory ring buffer.
Lines are ordered oldest to newest. Services that haven't produced
output return an empty list.

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
them to the loading page on the control host. The plug uses a
hostname-to-application lookup to resolve arbitrary hostnames (e.g.,
`vite.myapp.test` → application `myapp`, service `vite`) and redirects
to `/loading/:app_name/:service_name` on `bates.test`. This keeps the
loading page's connection on a stable hostname that isn't affected by
Caddy route updates when the app starts.

The control interface delegates to the process management layer for
starting, stopping, and querying application state.

The dashboard is a LiveView that subscribes to application-level state
changes via PubSub (`"app:<name>"`). The loading page is a blocking
controller that subscribes to service-level state changes
(`"service:<app>:<service>"`). Application GenServers broadcast state
transitions at both levels.
