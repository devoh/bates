# erlexec stdin piping for Caddy config delivery

**Date:** 2026-04-23
**Assumption tested:** erlexec can pipe a Caddyfile to Caddy's stdin
**Result:** Confirmed — using `:erlexec` 2.3.0 (not `:exec` 1.0.1)

## What was tested

### Round 1: `:exec` 1.0.1 (old hex package)

Three approaches tested, none fully satisfactory:

1. **`{stdin, content}` tuple** — Does not exist. Returns
   `{:invalid_option, {:stdin, ...}}`.
2. **`{stdin, Filename}` option** — Caddy receives EOF immediately
   despite file having content. Works for `cat` but not for Caddy.
3. **`:exec.send(os_pid, :eof)`** — `FunctionClauseError`. The 1.0.1
   version's `send/2` only accepts binary data, not `:eof`.
4. **Shell redirect workaround** — `sh -c 'caddy run -c - < file'`
   works but requires a temp file.

### Round 2: `:erlexec` 2.3.0 (current hex package)

The same library has two hex packages: `:exec` (stale at 1.0.1) and
`:erlexec` (current at 2.3.0). The 2.3.0 version supports
`:exec.send(os_pid, :eof)`.

Tested pattern:

```elixir
{:ok, pid, os_pid} = :exec.run_link(
  ~c"caddy run --adapter caddyfile -c -",
  [:stdin, :stdout, :stderr, :monitor]
)

:ok = :exec.send(os_pid, caddyfile_content)
:ok = :exec.send(os_pid, :eof)
```

Results:

1. **cat round-trip** — SUCCESS. Caddyfile content sent via `send/2`
   and closed with `:eof`. Output matches input exactly (223 bytes).
2. **Caddy with default ports** — SUCCESS. Caddy reads config from
   stdin, starts, generates TLS certs, serves on 443/80.
3. **Caddy with custom ports** — SUCCESS. `curl http://127.0.0.1:19876`
   returns the expected response body.

## Recommended approach

Switch the project's dependency from `:exec` to `:erlexec`:

```elixir
# mix.exs
{:erlexec, "~> 2.3"}
```

The API is the same (`:exec.run_link/2`, `:exec.send/2`, etc.) but
the package name changes. Then deliver the Caddyfile via:

```elixir
{:ok, pid, os_pid} = :exec.run_link(
  ~c"caddy run --adapter caddyfile -c -",
  [:stdin, :stdout, :stderr, :monitor]
)

:ok = :exec.send(os_pid, caddyfile_content)
:ok = :exec.send(os_pid, :eof)
```

No temp files. No shell wrappers. Clean stdin piping.

## Impact on the plan

- **Phase 1** (mix.exs): Change dependency from `{:exec, "~> 1.0"}`
  to `{:erlexec, "~> 2.3"}`.
- **Phase 5** (Caddy management): Use `send/2` + `:eof` pattern
  directly. No temp files or shell redirects needed.
- **Process.ex**: Verify existing `:exec.run_link/2` calls still work
  with erlexec 2.3.0 (API is compatible).

## Environment

- Caddy v2.9.1
- erlexec 2.3.0 (`:erlexec` hex package)
- Elixir 1.19.5, Erlang/OTP 27
- macOS (darwin, aarch64)
