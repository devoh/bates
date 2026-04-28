# Routing

Caddy runs as a managed child process in Bates's supervision tree. It
terminates SSL, handles HTTP/2 and WebSockets, and reverse-proxies requests
to application processes based on hostname.

## DNS Resolution

All `*.test` hostnames resolve to `127.0.0.1` via the macOS resolver. This
is a one-time system configuration, not managed by Bates:

```
# /etc/resolver/test
nameserver 127.0.0.1
```

No custom DNS server. No dynamic resolution.

## What Caddy Provides

- **Automatic HTTPS.** Caddy runs a local CA, issues certificates for
  `.test` hostnames automatically, and installs the root certificate into
  the system trust store. On first run, Caddy prompts for a password to
  modify the trust store — this is a one-time step. Because `.test` is
  not a public TLD, each site block must use `tls internal` to tell
  Caddy to use its local CA rather than attempting ACME.
- **HTTP/2** for all HTTPS connections.
- **WebSocket proxying** — transparent, no special configuration.
- **Concurrent connections** — handles many simultaneous requests.

## Ports

| Port | Purpose |
|------|---------|
| 443 | HTTPS (user-facing, all `.test` traffic) |
| 80 | HTTP (redirects to HTTPS) |

## Caddy Lifecycle

Bates generates a JSON config from the TOML configuration and pipes it
to Caddy on startup via stdin. No config file is written to disk.

If Caddy crashes, Bates restarts it with a freshly generated JSON
config and re-registers routes for any currently-running apps via the
admin API.

### Route Generation

Bates generates one route per routable service (any service with a
`hostname`), plus one for `bates.test` and a `*.test` catch-all for
unknown hostnames. Services without a `hostname` get no route. Each
route has a stable `@id` tag (e.g., `route:myapp.test`) for targeted
admin API updates.

## Dynamic Routes via Admin API

All routes are defined in the initial JSON config pointing to the
control interface. Routes are updated dynamically at runtime via the
Caddy admin API when apps start and stop.

When an app starts and gets a port assigned, `App.up/1` calls
`Caddy.update_route/2` to update the route's upstream to the assigned
port, adding a `handle_response` fallback for 502 errors that routes
to the control interface. When an app stops, `App.down/1` calls
`Caddy.revert_route/1` to point the route back to the control interface
only.

During the starting window (after port assignment but before the app is
accepting connections), Caddy's `handle_response` fallback routes
connection-refused 502 errors to the control interface, which serves
the loading page. This is correct behavior — the user sees the loading
page until the app is ready.

The `bates.test` route points directly to the control interface with no
dynamic updates — it is always handled by Bates.

The `*.test` catch-all route provides a friendly error via the control
interface for unknown hostnames (typos, stale bookmarks).

If the Caddy admin API call fails (e.g., Caddy crashed), the app starts
anyway and logs a warning. It is running but not routable until Caddy
recovers. On Caddy crash recovery, routes for running apps are
re-registered automatically.

Caddy's admin API listens on `localhost:2019`.

## Control Interface Routing

Within the Phoenix application, an `AppRedirect` plug in the browser
pipeline handles app-domain requests before they reach any route. When
a request arrives with a `.test` hostname other than `bates.test`, the
plug resolves the hostname to an application and service name using a
lookup map from `ProcessSupervisor.hostname_lookup/0` and redirects to
the loading page at `bates.test/loading/:app_name/:service_name`. The
redirect targets the control host (`bates.test`) so the loading page's
connection is not disrupted when Caddy updates the app's route upstream
on startup.

Requests to `bates.test` pass through the plug unchanged and are
handled by the normal route table: the dashboard at `/`, the loading
page at `/loading/:app_name/:service_name`, and a catch-all fallback
returning 404.

## How It Connects

- **Bates** starts Caddy as a child process, generating the initial JSON
  config from the TOML configuration with all routes pointing to the control
  interface.
- **Control interface** is the default upstream for all service routes,
  handling on-demand startup when an app is down.
- **Process management** notifies Caddy when services start and stop.
  `App.up/1` updates the route upstream to the assigned port via the admin
  API. `App.down/1` reverts the route to the control interface. If Caddy
  is unavailable, the app starts anyway and the route is updated when Caddy
  recovers.
