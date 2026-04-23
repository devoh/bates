# Procfile Managers

A survey of tools that run multiple processes from a `Procfile`. These are
relevant to Conjure because the Procfile format is a potential plugin point for
process discovery within applications.

## The Procfile Format

A `Procfile` is a plain-text file where each line declares a process type and
the command to run it:

```
web: bundle exec puma -C config/puma.rb
worker: bundle exec sidekiq
clock: bundle exec clockwork clock.rb
```

Foreman popularized this format. Heroku adopted it for deployments, which made
it a de facto standard across the Ruby ecosystem and beyond.

## Foreman (Ruby)

- **Source:** [ddollar/foreman](https://github.com/ddollar/foreman)
- **Stars:** 6.1k
- **Status:** Maintained (v0.88.1, April 2024)

The original. Reads `Procfile` and `.env`, assigns ports, multiplexes output
with color-coded prefixes. Can export to systemd, upstart, and other init
systems.

Limitations: no per-process restart, no way to attach a debugger, stdout
buffering issues (processes think they're logging to a file, so output lags
and loses color).

## Overmind (Go)

- **Source:** [DarthSim/overmind](https://github.com/DarthSim/overmind)
- **Stars:** 3.6k
- **Status:** Actively maintained

The modern standard for Procfile management. Built on tmux, which solves
Foreman's core UX problems:

- **Per-process restart.** Restart one process without stopping the others.
- **Debugger attachment.** `overmind connect <process>` drops you into a tmux
  session where you can interact with the process (e.g., `binding.pry`).
- **No output buffering.** tmux uses ptys, so processes behave as if they're
  in a real terminal (colored output, no lag).
- **Auto-restart.** Can restart specific processes on crash.
- **Daemon mode.** Run in the background, connect later.
- **Process scaling.** Run N instances of a process type.
- **Socket-based control.** TCP or Unix socket for commands.

Reads `.overmind.env` in addition to `.env`.

Created by Evil Martians. Requires tmux as a dependency.

## Hivemind (Go)

- **Source:** [DarthSim/hivemind](https://github.com/DarthSim/hivemind)
- **Stars:** ~1.5k

Lighter-weight sibling of Overmind by the same author. Same pty-based output
handling but without the tmux dependency or interactive features. Good for CI
or environments where you just want to run processes and see output.

## Others

- **Honcho** (Python): Foreman port for Python projects.
- **Ultraman** (Rust): Foreman port with identical semantics.
- **Prox** (Go): Adds Unix socket control and per-process log tailing.

## Relevance to Conjure

Conjure's TOML configuration already defines services per-application. A
Procfile plugin could optionally discover processes from an app's `Procfile`
instead of requiring manual configuration:

- Read `Procfile` from the application's working directory.
- Map process types to Conjure services.
- Fall back to TOML-defined services when no `Procfile` exists.
- Allow TOML overrides even when a `Procfile` is present.

Overmind's per-process restart and tmux attachment are worth studying as UX
patterns, though Conjure's architecture (BEAM-based supervision) may offer
equivalent capabilities through OTP process management rather than tmux.
