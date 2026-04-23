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
  the system trust store. No manual certificate setup.
- **HTTP/2** for all HTTPS connections.
- **WebSocket proxying** — transparent, no special configuration.
- **Concurrent connections** — handles many simultaneous requests.

## Ports

| Port | Purpose |
|------|---------|
| 443 | HTTPS (user-facing, all `.test` traffic) |
| 80 | HTTP (redirects to HTTPS) |
| 2019 | Caddy admin API (localhost only) |

## Static Routes with Fallback

All routes are registered at Caddy startup based on the TOML configuration.
Routes are never added or removed at runtime.

Each application route has two upstreams in priority order:

1. **Primary:** the application's assigned port (`127.0.0.1:<port>`).
2. **Fallback:** the control interface.

When the application is running, the primary upstream handles the request
directly. When the application is down, the TCP connection is refused
immediately and Caddy falls back to the control interface, which triggers
on-demand startup. See [Control Interface](control-interface.md).

The `conjure.test` route points directly to the control interface with no
fallback — it is always handled by Conjure.

### Route Registration

On startup, Conjure registers all routes via Caddy's admin API on
`localhost:2019`:

```
POST localhost:2019/config/apps/http/servers/srv0/routes
{
  "@id": "<name>",
  "match": [{"host": ["<name>.test"]}],
  "handle": [{
    "handler": "reverse_proxy",
    "upstreams": [{"dial": "127.0.0.1:<port>"}],
    "handle_errors": [{
      "handler": "reverse_proxy",
      "upstreams": [{"dial": "127.0.0.1:<control-interface-port>"}]
    }]
  }]
}
```

The `@id` field allows direct access to individual routes by process name.

Routes are registered once and persist for the lifetime of the Caddy
process. Because port assignments are stable across process stop/start
cycles, the routes never need updating.

## How It Connects

- **Conjure** starts Caddy as a child process and registers all routes at
  startup using port numbers from the TOML configuration.
- **Control interface** is the fallback for all application routes, handling
  on-demand startup when an app is down.
- **Process management** is independent of routing. Starting or stopping a
  process does not change any Caddy configuration — the fallback mechanism
  handles both states transparently.
