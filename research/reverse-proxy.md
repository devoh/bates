# Reverse Proxy

Evaluation of off-the-shelf reverse proxies to replace Conjure's custom HTTP
proxy. The custom proxy handles request parsing, forwarding, and response
streaming manually but does not support SSL, WebSockets, HTTP/2, or
concurrent connections. An off-the-shelf proxy gets all of these for free.

## Decision

Use Caddy. Conjure manages it as a child process and configures it
dynamically via its REST API.

## Why Caddy

### Automatic HTTPS with a Local CA

Caddy runs its own certificate authority for internal and local hostnames.
When it sees a `.test` domain, it issues a short-lived certificate from its
local CA and installs the root certificate into the system trust store. No
`mkcert`, no manual CA setup, no certificate files.

This is the single biggest reason to use Caddy. SSL support is a core
Conjure requirement and Caddy makes it zero-configuration.

### Dynamic Configuration via REST API

Caddy exposes an admin API on `localhost:2019` that accepts JSON
configuration changes at runtime. Changes are atomic, zero-downtime, and
rolled back automatically if invalid.

Adding a route when a process starts:

```bash
curl -X POST http://localhost:2019/config/apps/http/servers/srv0/routes \
  -H "Content-Type: application/json" \
  -d '{
    "@id": "myapp",
    "match": [{"host": ["myapp.test"]}],
    "handle": [{
      "handler": "reverse_proxy",
      "upstreams": [{"dial": "127.0.0.1:4200"}]
    }]
  }'
```

Removing a route when a process stops:

```bash
curl -X DELETE http://localhost:2019/id/myapp
```

The `@id` field enables direct access to individual routes without knowing
their position in the array. This maps cleanly to Conjure's process names.

### What Else It Provides

- **WebSocket support** — proxied transparently.
- **HTTP/2** — automatic for HTTPS connections.
- **Connection pooling and concurrency** — handles many simultaneous
  connections. The custom proxy was limited to one at a time.
- **Health checks** — can be configured per-upstream.
- **Single binary** — installable via `brew install caddy`. No runtime
  dependencies.

## Why Not Traefik

Traefik is designed around Docker labels and container orchestration. It
works without Docker via a file provider (write TOML/YAML, Traefik watches
for changes via fsnotify), but this is clearly a secondary mode.

The bigger problem: Traefik has no built-in local CA. HTTPS for local
development requires `mkcert` as a separate tool to generate certificates,
plus manual configuration to point Traefik at the certificate files. This
negates the main benefit of using an off-the-shelf proxy.

## Integration with Conjure

### Caddy as a Managed Process

Conjure starts Caddy as a child process in its supervision tree, similar to
how it manages application processes. Caddy listens on ports 80 and 443 (or
configured alternatives) for HTTP and HTTPS traffic.

### Route Lifecycle

When a Conjure process starts:

1. The process gets a port assigned (e.g., 4200).
2. Conjure POSTs a route to Caddy's admin API mapping `<name>.test` to
   `127.0.0.1:<port>`.
3. Caddy automatically issues an SSL certificate for `<name>.test`.

When a Conjure process stops:

1. Conjure DELETEs the route from Caddy via the admin API.

### The Control Interface

The control interface (dashboard and JSON API) runs as an internal HTTP
server within Conjure on its own port. Conjure registers `conjure.test` as
a Caddy upstream pointing to that port, just like any other application.
This is added as a permanent route on Caddy startup, not tied to any
application process lifecycle.

### What This Replaces

The custom proxy code is eliminated entirely:

- Request parsing (HTTP method, headers, body, `100-continue`)
- Request forwarding and response streaming
- Chunked transfer encoding handling
- HTTP response construction
- Error responses (502, 504)

### What Remains Unchanged

- **DNS server** — still needed. Caddy doesn't do DNS. The `.test` resolver
  must continue resolving all configured hostnames to `127.0.0.1`.
- **Process management** — unchanged. OTP supervision, port assignment,
  erlexec execution.
- **Configuration** — TOML parsing unchanged. The config drives both process
  management and Caddy route registration.

## Port Allocation

With Caddy in front, the port layout becomes:

| Port | Service |
|------|---------|
| 42000 | Conjure DNS server (UDP) |
| 80 | Caddy HTTP (redirects to HTTPS) |
| 443 | Caddy HTTPS (reverse proxy to applications) |
| 2019 | Caddy admin API (localhost only) |
| 4200+ | Application processes (not exposed directly) |

Application ports are internal — users interact with `https://myapp.test`
on port 443, not `http://localhost:4200`.
