# Implementation Notes

Collected implementation details from the spec design phase. These are
decisions and preferences that inform future implementation but don't
belong in the domain specs.

## OS Process Management: erlexec

`erlexec` is the likely choice for managing OS processes. It provides:

- Linked execution (the managing Elixir process is notified on exit).
- stdout/stderr capture as messages.
- Signal-based stop (graceful shutdown via SIGTERM).
- Working directory configuration.
- Environment variable passthrough.

Alternative: `Port` / `System.cmd`, but these lack signal control and
linked lifecycle management.

## OTP Structure

- **ProcessSupervisor** as a `DynamicSupervisor`. Children are started
  asynchronously so initialization doesn't block.
- **One GenServer per application**, supervising its own services.
- **Registry** keyed by application name for lookup from any part of
  the system (routing, control interface) without direct process
  references.
- Process state changes broadcast via **Phoenix PubSub**. LiveViews
  subscribe to receive real-time updates.

## Caddy Invocation

Start Caddy with:

```
caddy run --adapter caddyfile -c -
```

The Caddyfile is generated in memory and piped to stdin. No config file
written to disk. If Caddy crashes, OTP restarts it and pipes a freshly
generated Caddyfile.

## Caddyfile Template

Given services with hostnames, the generated Caddyfile follows this
pattern:

```
conjure.test {
  tls internal
  reverse_proxy 127.0.0.1:<control-interface-port>
}

myapp.test {
  tls internal
  handle_errors {
    @502 expression `{err.status_code} == 502`
    handle @502 {
      reverse_proxy 127.0.0.1:<control-interface-port>
    }
  }
  reverse_proxy 127.0.0.1:<port>
}
```

**Important:** `handle_errors` is required, not `handle_response`.
When an upstream is unreachable (connection refused), Caddy generates a
502 internally — this does NOT pass through `handle_response` (which
only fires on actual upstream responses). `handle_errors` catches
Caddy's internal error responses. Verified with Caddy v2.9.1.

Each routable service gets the same block structure. The worker pattern
(no hostname, no route) gets nothing. `conjure.test` routes directly
to the control interface with no fallback.

## Control Interface Functions

The control interface delegates to the process management layer:

- `Process.up/1` — start an application
- `Process.down/1` — stop an application
- `ProcessSupervisor.status/0` — list all applications and states

These are the internal API that the LiveViews and JSON API call.

## Port Detection (Elixir)

Dynamic port detection equivalent to Ruby's `Socket.bind(0)`:

```elixir
{:ok, socket} = :gen_tcp.listen(0, [])
{:ok, port} = :inet.port(socket)
:gen_tcp.close(socket)
port
```
