# Local Development Servers

A survey of projects that manage local development environments for web
applications on macOS. These represent the historical lineage of the
problem-space that Bates operates in.

## Pow

- **Source:** [basecamp/pow](https://github.com/basecamp/pow)
- **Language:** CoffeeScript (70%), JavaScript, Shell
- **Status:** Archived May 2020. Read-only. No longer maintained.
- **Stars:** 3.4k

Zero-configuration Rack server for macOS. Symlink-based app discovery: link a
working directory into `~/.pow` and it maps to a local hostname. Built-in DNS
resolution and a reverse proxy.

**Architecture:**
- DNS server intercepts `.dev` lookups (now unusable since Google registered
  `.dev` in 2017 as a real TLD).
- Spawns Rack processes on demand when a request arrives.
- Status API via a magic hostname: `curl -H host:pow localhost/status.json`.
- Restart triggered by `touch tmp/restart.txt`.

**What killed it:** The `.dev` TLD registration, tight coupling to Rack/Ruby,
and dependency on older Ruby version managers (rbenv/RVM, not asdf). The
CoffeeScript codebase made contributions difficult in its later years.

**Ideas worth borrowing:**
- Zero-configuration philosophy (convention over configuration for app
  discovery).
- Status API via a reserved hostname.

**Ideas to avoid:**
- File-touch restart mechanism. Filesystem watching or DNS-triggered lifecycle
  management is better.
- Hardcoding a TLD that could be registered.

## Puma-dev

- **Source:** [puma/puma-dev](https://github.com/puma/puma-dev)
- **Language:** Go
- **Status:** Actively maintained. Last updated December 2025.
- **Stars:** 1.8k

Self-described "emotional successor to Pow." The closest living project to what
Bates is building. Uses `.test` TLD. Automatic HTTPS via a local CA.
WebSocket support.

**Architecture:**
- DNS resolution via `/etc/resolver/test` on macOS.
- Local CA for automatic SSL certificate generation.
- Spawns Puma (Ruby) processes on first HTTP request.
- Auto-sleep: processes shut down after a configurable period of inactivity.
- Symlink-based app discovery (same model as Pow).
- Status API via `puma-dev` hostname.

**Limitations relevant to Bates:**
- Rack-only. Spawns Puma processes, so it's locked to Ruby web apps.
- Single-application-per-hostname. No concept of multi-service applications
  (web server + worker + database).
- No environment setup orchestration (no equivalent of loading the right
  Ruby/Node version or setting per-app env vars from a config file).
- No Procfile support for defining multiple processes within an app.

**Ideas worth borrowing:**
- Auto-sleep on inactivity for resource management.
- Local CA approach for HTTPS (well-documented and proven).
- macOS DNS resolver setup is the most current reference implementation.

## Prax

- **Source:** [ysbaddaden/prax](https://github.com/ysbaddaden/prax) (Ruby),
  [ysbaddaden/prax.cr](https://github.com/ysbaddaden/prax.cr) (Crystal)
- **Language:** Ruby (original), Crystal (rewrite)
- **Status:** Dead. Ruby version unmaintained. Crystal version last committed
  March 2018, last release December 2018.
- **Stars:** 153 (Crystal version)

Pure Ruby alternative to Pow. Rack-only, symlink-based, with wildcard subdomain
support. The author rewrote it in Crystal to eliminate Ruby version manager
dependencies by compiling to a single binary.

**Notable only for one insight:** The move from Ruby to Crystal was motivated
by distribution pain. A development tool that requires its own runtime version
management is a bad experience. Compiling to a binary (or running on a VM like
BEAM) sidesteps this.

## Foreman

- **Source:** [ddollar/foreman](https://github.com/ddollar/foreman)
- **Language:** Ruby
- **Status:** Maintained. v0.88.1 released April 2024.
- **Stars:** 6.1k

Process manager for Procfile-based applications. Solves a narrower problem than
the others: it runs multiple processes defined in a `Procfile`, assigns ports,
and multiplexes output. No DNS, no SSL, no routing.

**Architecture:**
- Reads `Procfile` for process definitions.
- Reads `.env` for environment variables.
- Assigns `$PORT` to each process.
- Multiplexes stdout/stderr with color-coded prefixes.
- Single-application only.

**Ideas worth borrowing:**
- The `Procfile` format is a de facto standard. Bates could optionally read
  Procfiles from application directories as a plugin for process discovery
  (as noted in the project's CLAUDE.md).
- `.env` file loading is a well-understood pattern.

## Gaps in the Landscape

The consistent gaps across all of these projects, which define Bates's
opportunity:

1. **Multi-application orchestration.** Every project above is single-app.
   None handles "I need apps A, B, and C running together with their
   respective services."

2. **Language agnosticism.** Pow, Puma-dev, and Prax are all Rack/Ruby-locked.
   Foreman is language-agnostic but doesn't handle DNS or SSL.

3. **Environment setup.** None manage environment configuration per-app (e.g.,
   loading the right Ruby/Node version, setting env vars). Bates's TOML
   config addresses this.

4. **Service dependencies.** No project handles "app A needs PostgreSQL and
   Redis running." `docker-compose` is the closest thing, but it's a
   container-first tool, not a native local development tool.

5. **Unified DNS + process management + SSL.** Foreman does processes.
   Puma-dev does DNS + SSL. Nobody combines all three with multi-app support.
