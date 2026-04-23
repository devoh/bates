# Routing

Caddy runs as a managed child process in Conjure's supervision tree. It
terminates SSL, handles HTTP/2 and WebSockets, and reverse-proxies requests
to application processes based on hostname.

## DNS Resolution

All `*.test` hostnames resolve to `127.0.0.1` via the macOS resolver. This
is a one-time system configuration, not managed by Conjure:

```
# /etc/resolver/test
nameserver 127.0.0.1
port 443
```

No custom DNS server. No dynamic resolution.

## What Caddy Provides

- **Automatic HTTPS.** Caddy runs a local CA, issues certificates for
  `.test` hostnames automatically, and installs the root certificate into
  the system trust store. On first run, Caddy prompts for a password to
  modify the trust store — this is a one-time step.
- **HTTP/2** for all HTTPS connections.
- **WebSocket proxying** — transparent, no special configuration.
- **Concurrent connections** — handles many simultaneous requests.

## Ports

| Port | Purpose |
|------|---------|
| 443 | HTTPS (user-facing, all `.test` traffic) |
| 80 | HTTP (redirects to HTTPS) |

## Caddy Lifecycle

Conjure generates a Caddyfile from the TOML configuration and pipes it
to Caddy on startup. No config file is written to disk.

If Caddy crashes, Conjure restarts it and pipes a freshly generated
Caddyfile. The config is generated from the TOML configuration each
time, so it always reflects the current state.

### Route Generation

Conjure generates one route per routable service (any service with a
`hostname`), plus one for `conjure.test`. Services without a `hostname`
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

The `conjure.test` route points directly to the control interface with no
fallback — it is always handled by Conjure.

Port assignments are stable across service stop/start cycles within a
Conjure session, so routes never need updating at runtime. Ports are
dynamically assigned at init time and may differ across Conjure restarts,
but the Caddyfile is regenerated on each start.

## How It Connects

- **Conjure** starts Caddy as a child process, generating the routing
  configuration from the TOML configuration.
- **Control interface** is the fallback for all service routes, handling
  on-demand startup when an app is down.
- **Process management** is independent of routing. Starting or stopping
  services does not change any Caddy configuration — the fallback mechanism
  handles both states transparently.
