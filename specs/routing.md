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

Conjure generates a Caddyfile like:

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

api.test {
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

One block per configured application, plus one for `conjure.test`. The
pattern is the same for every app — only the hostname and port change.

## Static Routes with Fallback

All routes are defined in the generated Caddyfile. Routes are never changed
at runtime.

Each application route has two upstreams in priority order:

1. **Primary:** the application's assigned port (`127.0.0.1:<port>`).
2. **Fallback:** the control interface.

When the application is running, the primary upstream handles the request
directly. When the application is down, the TCP connection is refused
immediately and Caddy falls back to the control interface, which triggers
on-demand startup. See [Control Interface](control-interface.md).

The `conjure.test` route points directly to the control interface with no
fallback — it is always handled by Conjure.

Because port assignments are stable across process stop/start cycles, the
routes never need updating.

## How It Connects

- **Conjure** starts Caddy as a child process, generating the Caddyfile
  from the TOML configuration and piping it to stdin.
- **Control interface** is the fallback for all application routes, handling
  on-demand startup when an app is down.
- **Process management** is independent of routing. Starting or stopping a
  process does not change any Caddy configuration — the fallback mechanism
  handles both states transparently.
