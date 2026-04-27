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

Bates generates a Caddyfile from the TOML configuration and pipes it
to Caddy on startup. No config file is written to disk.

If Caddy crashes, Bates restarts it and pipes a freshly generated
Caddyfile. The config is generated from the TOML configuration each
time, so it always reflects the current state.

### Route Generation

Bates generates one route per routable service (any service with a
`hostname`), plus one for `bates.test`. Services without a `hostname`
get no route.

## Static Routes with Fallback

All routes are defined in the generated Caddyfile. Routes are never changed
at runtime.

Each routable service gets a route with two upstreams in priority order:

1. **Primary:** the service's assigned port (`127.0.0.1:<port>`).
2. **Fallback:** the control interface.

When the service is running, the primary upstream handles the request
directly. When it's down, the TCP connection is refused immediately and
Caddy falls back to the control interface, which starts the entire
application (all services, not just the one that was requested). See
[Control Interface](control-interface.md).

The `bates.test` route points directly to the control interface with no
fallback — it is always handled by Bates.

Port assignments are stable across service stop/start cycles within a
Bates session, so routes never need updating at runtime. Ports are
dynamically assigned at init time and may differ across Bates restarts,
but the Caddyfile is regenerated on each start.

## Control Interface Routing

Within the Phoenix application, an `AppRedirect` plug in the browser
pipeline handles app-domain requests before they reach any route. When
a request arrives with a `.test` hostname other than `bates.test`, the
plug resolves the hostname to an application name using a lookup map
from `ProcessSupervisor.hostname_lookup/0` and redirects to the
loading page (`/loading/<name>`). When the requested hostname differs
from the application's default hostname (e.g., `vite.myapp.test` for
application `myapp`), the original hostname is passed as a query
parameter so the loading page knows which specific service to wait for.

Requests to `bates.test` pass through the plug unchanged and are
handled by the normal route table: the dashboard at `/`, the loading
page at `/loading/:app_name`, and a catch-all fallback returning 404.

## How It Connects

- **Bates** starts Caddy as a child process, generating the routing
  configuration from the TOML configuration.
- **Control interface** is the fallback for all service routes, handling
  on-demand startup when an app is down.
- **Process management** is independent of routing. Starting or stopping
  services does not change any Caddy configuration — the fallback mechanism
  handles both states transparently.
