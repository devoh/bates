# Conjure

Local multi-application development server.

**Repo:** tylerhunt/conjure
**Methodology:** Context-Driven Development (CDD). See `CDD.md`.

## Additional Context

If `.internal/` exists, read it for additional project context. That folder is
gitignored.

## What This Is

Conjure is a local development server that supports running multiple server
applications simultaneously. It is configured by a TOML file with each
application given its own section that defines the working path, environment
setup, and the services required to run the application.

The magic is in hooking into DNS resolution to automatically spin up
applications on demand when a DNS lookup for a local hostname (`*.test`)
occurs. It also handles automatically generating SSL certificates for the
applications by routing requests through a reverse proxy.

## Similar Projects

These projects represent an historical record of the problem-space, but have
largely been abandoned. `docker-compose` seems the most prevalent successor.

### Pow

  - [web](https://web.archive.org/web/20150222190737/http://pow.cx/)
  - [source](https://github.com/basecamp/pow)

Zero-configuration Rack server for macOS. Simple single-command installation
script. Relies on a symlink of the working directory into `/.pow` to map the
applications/domains.

Uses `.dev` TLD, which has since been registered and can no longer be used for
local development (use `.test` instead).

Rack-only and relies on older `rbenv`/RVM projects for Ruby (not `asdf`).

Also supports mapping domains to arbitrary port numbers. Serves static files
from `public/` in the working directory, and can be used to serve static-only
projects as long as they have a `public/`.

Relies on `touch tmp/restart.txt` to trigger restarts.

Has status endpoints using the hostname `pow` (e.g. `curl -H host:pow
localhost/status.json`).

CLI available via [https://github.com/powder-rb/powder]().

### Puma-dev

  - [source](https://github.com/puma/puma-dev)

Successor to Pow written in Go. Uses `.test` TLD with support to multiple TLDs.
Automatic SSL and websocket support.

Instructions in `README.md` on setting up the root CA for SSL.

Provides a status API via `puma-dev` hostname: `curl -H "Host: puma-dev"
localhost/status` (includes booting, running, or dead status, app directory,
and last 1024 lines of application log output).

### prax

  - [web](https://ysbaddaden.github.io/prax/)
  - [source](https://github.com/ysbaddaden/prax)

Pure Ruby alternative to Pow. Rack-only and symlink-based with DNS-based with
support for wild-card subdomains.

### Foreman

  - [web](https://web.archive.org/web/20120106070247/http://ddollar.github.com/foreman/)
  - [source](https://github.com/ddollar/foreman)

Manager for Procfile-based applications. Only works with a single application.
Handle process definition and `$PORT` assignment, but not DNS/SSL. Provides a
CLI for starting, stopping, and restarting the server and its sub-processes.

Reads a `.env` file if it exists in the current directory to define environment
variables.

Might be able to piggy-back off the `Procfile` in each application instead of
relying on hand-configuring the services. This should be done through a plugin
while still allowing manual process definition in the configuration file.
