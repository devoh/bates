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

Conjure generates a Caddyfile in memory from the TOML configuration and
starts Caddy with `caddy run --adapter caddyfile -c -`, piping the config
to stdin. No config file is written to disk.

If Caddy crashes, OTP restarts the process and pipes a freshly generated
Caddyfile to it. The config is generated from the TOML configuration each
time, so it always reflects the current state. There is no startup ordering
issue — Caddy receives its full configuration on launch.

### Generated Caddyfile

Conjure generates a Caddyfile with one block per routable service (any
service with a `hostname`), plus one for `conjure.test`. Given this config:

```toml
[myapp]
root = "~/Code/myapp"

[myapp.services.web]
command = "bin/rails server"
hostname = true

[myapp.services.vite]
command = "bin/vite dev"
hostname = "vite.myapp"

[myapp.services.worker]
command = "bundle exec sidekiq"
```

Conjure generates:

```
conjure.test {
  reverse_proxy 127.0.0.1:<control-interface-port>
}

myapp.test {
  reverse_proxy 127.0.0.1:<port> {
    @fallback {
      status 502
    }
    handle_response @fallback {
      reverse_proxy 127.0.0.1:<control-interface-port>
    }
  }
}

vite.myapp.test {
  reverse_proxy 127.0.0.1:<port> {
    @fallback {
      status 502
    }
    handle_response @fallback {
      reverse_proxy 127.0.0.1:<control-interface-port>
    }
  }
}
```

The worker service has no `hostname`, so it gets no route. The pattern is
the same for every routable service — only the hostname and port change.

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

- **Conjure** starts Caddy as a child process, generating the Caddyfile
  from the TOML configuration and piping it to stdin.
- **Control interface** is the fallback for all service routes, handling
  on-demand startup when an app is down.
- **Process management** is independent of routing. Starting or stopping
  services does not change any Caddy configuration — the fallback mechanism
  handles both states transparently.
