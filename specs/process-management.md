# Process Management

Each application in the TOML configuration becomes a `Conjure.Process`
GenServer, supervised by a DynamicSupervisor. Processes wrap OS-level
commands (e.g., `bundle exec puma`) and manage their lifecycle through OTP.

## Process Lifecycle

A process has three states:

| State | Meaning |
|-------|---------|
| **down** | Registered but not running. No OS process exists. |
| **up** | Running. An OS process is alive and linked. |
| **crashed** | The OS process exited with a non-zero status. |

Transitions:

- `down` → `up`: The `up` command starts the OS process via `erlexec`.
- `up` → `down`: The `down` command sends a stop signal via `erlexec`.
- `up` → `down`: The OS process exits cleanly (status 0).
- `up` → `crashed`: The OS process exits with a non-zero status.
- Calling `up` on an already-running process is a no-op.
- Calling `down` on an already-stopped process is a no-op.

Processes use `restart: :transient`, meaning OTP only restarts them if they
terminate abnormally. A clean exit or a crash leaves the process stopped
until explicitly restarted.

## Configuration

Each TOML table in `config.toml` defines one process:

```toml
[myapp]
command = "bin/rails server -p $PORT"
dir = "~/Code/myapp"

[myapp.env]
RAILS_ENV = "development"
```

| Field | Required | Description |
|-------|----------|-------------|
| `command` | Yes | Shell command to run. `$PORT` is replaced with the assigned port. |
| `dir` | Yes | Working directory. Supports `~` expansion. |
| `port` | No | Override the auto-assigned port. |
| `env` | No | Environment variables passed to the OS process. |

The `PORT` environment variable is always set, even if `$PORT` does not
appear in the command string.

## Port Assignment

Ports are assigned from a monotonically increasing counter starting at 4200.
The counter is an OTP Agent (`Conjure.PortNumber`). Each process that does
not specify an explicit port gets the next available number.

Port assignment happens at process init time, not at startup of the OS
process. A process keeps its assigned port for its entire lifetime, even
across stop/start cycles.

## Supervision

ProcessSupervisor is a DynamicSupervisor. On startup, it reads the TOML
configuration and starts a child GenServer for each application. Starting
children is done asynchronously via `Task.start/1` so the supervisor can
finish initialization without blocking.

All processes are registered in a Registry (`Conjure.ProcessRegistry`)
keyed by process name. This enables lookup by name from any part of the
system (routing, control interface) without holding direct process
references.

## Process Execution

OS processes are managed through `erlexec`, which provides:

- Linked execution (the GenServer is notified on exit).
- stdout/stderr capture (logged via Elixir's Logger with the process name
  as a prefix).
- Signal-based stop (graceful shutdown).
- Working directory and environment variable configuration.

## How It Connects

- **Routing** uses process names and ports from the TOML configuration to
  register static Caddy routes at startup. Routing does not interact with
  process lifecycle — the fallback mechanism handles down apps transparently.
- **Control interface** calls `Process.up/1` and `Process.down/1` to control
  individual processes, and `ProcessSupervisor.status/0` to list all
  processes and their states. It is also the fallback upstream for Caddy
  routes, triggering on-demand startup when a request arrives for a down
  app.
