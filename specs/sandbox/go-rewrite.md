# Rewrite Evaluation: Elixir → Go

**Status:** Research and recommendation. Not a decision. No code has been
written and no plan has been created.

**Date:** 2026-08-22

**Question asked:** Should Bates be rewritten to make it easier to
distribute and install — no Erlang VM, no convoluted launch commands?
Is Go the right pick?

**Short answer:** Go is the right pick, but not for the reasons given.
The distribution complaint is mostly a packaging gap, not a language
problem. The real case for Go is that Caddy is a Go library, and that a
Go binary doesn't leak a runtime into the environment of the child
processes Bates exists to spawn.

## Codebase Inventory

Measured on 2026-08-22 at commit `1666890`.

| Area | Files | Lines |
|------|-------|-------|
| `source/lib/` | 42 `.ex` + 2 `.heex` | 4,718 |
| `source/test/` | 30 `.exs` (+3 support `.ex`) | 5,397 |

Runtime dependencies today:

- **Caddy** binary on `$PATH` (`brew install caddy`), run as a managed
  child process.
- **erlexec** — an Elixir wrapper around a compiled C++ port program.
- **Phoenix / LiveView / PubSub** for the control interface.
- Optional per-app tooling: `asdf`, `direnv`, `postgres`/`initdb`.

Distribution today: a Mix release (`batesd`) plus an escript (`bates`),
plus a hand-written shell wrapper installed by a `:steps` callback in
`source/mix.exs` that renames `bin/batesd` → `bin/batesd-orig` to hide
the release launcher's subcommand dispatcher.

## Where the Stated Diagnosis Is Wrong

Three corrections, because acting on the stated diagnosis would buy
less than expected.

**"No Erlang VM" isn't the user's problem.** `mix release` bundles ERTS
by default. Nobody installing Bates needs Erlang. What they need is a
tarball or a Homebrew bottle, and `README.md` currently tells them to
run `mix deps.get && mix release` instead. That's a packaging gap.

**"Convoluted launch commands" is self-inflicted.** The wrapper hack at
`source/mix.exs:65` exists because the release launcher wants a
subcommand. It's about 40 lines of shell, written once, never touched
again. Ugly, but not worth 10k lines of rewrite.

**Single-binary-ness doesn't survive contact with reality.** A Go
`bates` still needs `brew install caddy`, `/etc/resolver/test`, and
`caddy trust`. That trades a two-artifact install for a one-artifact
install that still has three setup steps. Marginal — *unless* the proxy
gets embedded, which is the whole point below.

## The Real Case for Go

**1. Caddy v2 is a Go library.** Importing it (or dropping to
`net/http/httputil.ReverseProxy` + `certmagic`, Caddy's TLS and local-CA
package) runs the proxy in-process. That deletes:

- `source/lib/bates/caddy.ex` — 338 lines of JSON config generation, an
  admin-API HTTP client, crash detection, and route re-registration.
- The `caddy` prerequisite check in `prerequisites.ex` and the
  `brew install caddy` setup step.
- The entire "Caddy died, restart it, re-`PATCH` every route" failure
  class (`caddy.ex:77` onward).

Route updates become a mutex and a map lookup instead of
`PATCH http://localhost:2019/id/route:foo.test`. This is the largest
simplification available to this codebase, and it's only available in
Go.

**2. The BEAM leaks into child environments.** See `scrub_path/0` at
`source/lib/bates/app.ex:896`. The release launcher prepends its own
`erts-*/bin` and `bin` to `$PATH`; children inherit it; a user's
`mix phx.server` then resolves `erl` to Bates's release `erl` and dies
looking for `start.boot`. It's patched. The next leak will need
patching too. Bates's entire product is the environment it hands to
child processes — a hosting runtime that contaminates that environment
is a structural mismatch. A Go binary has no runtime to leak.

**3. erlexec is a C++ port program.** It ships fine inside a release
built on the target arch, but it's real friction for prebuilt
cross-arch binaries. Go's `os/exec` covers what Bates uses it for.

## What Gets Worse

Be honest about this before committing.

- **LiveView.** `dashboard_live.ex` is 332 lines and gets real-time
  updates with zero JavaScript. In Go that's SSE or WebSocket plumbing,
  `html/template`, and probably htmx. Roughly 250–400 lines newly owned.
  This is the one place the rewrite is strictly worse per feature.
- **Supervision semantics.** `DynamicSupervisor` + `Registry` +
  `restart: :transient` is ~70 lines in `process_supervisor.ex`. In Go
  it's a struct, a mutex, a map, and a hand-rolled restart policy.
- **`:digraph_utils.topsort`** for dependency ordering becomes ~40 lines
  of Kahn's algorithm.
- **Remote console.** `bin/batesd remote` into a live daemon is a
  genuinely good debugging tool with no Go equivalent.
- **5,397 lines of tests.** They don't port. They do make excellent
  conformance specs.

## Alternative Considered: Burrito

[Burrito](https://github.com/burrito-elixir/burrito) wraps a Mix
release into a single self-extracting binary with cross-compilation. It
fixes the artifact-count problem in an afternoon.

It doesn't fix the `$PATH` leakage, the erlexec compile step, or the
external Caddy process. It adds first-run extraction latency and macOS
codesigning friction. If distribution were the only complaint, this is
the correct answer and the rewrite should be dropped. It isn't the only
complaint.

## Recommendation

Go, staged. Don't big-bang it.

1. **Port the CLI first.** `specs/cli.md` exists, the CLI is ~600 lines
   across `source/lib/bates/cli/*.ex`, and it only speaks JSON over HTTP
   to the daemon. The daemon stays untouched.
   *Verify:* the Go `bates` passes the same behaviors the Elixir
   `cli_test.exs` suite covers, against the running Elixir daemon.
2. **Spike embedded Caddy.** Half a day. See the checklist below.
   *Verify:* an in-process proxy serves `https://spike.test` with a
   trusted internal-CA cert and a route mutated at runtime.
3. **Port the daemon**, using the Elixir test suite as the behavioral
   oracle and `source/test/fixtures/*.toml` as the config corpus.
   *Verify:* the Elixir `bates` escript works unmodified against the Go
   daemon — the JSON API is the contract and must not drift.
4. **Dashboard last**, SSE + `html/template`.
   *Verify:* status transitions appear without a page reload.

If step 2 fails — Caddy can't be embedded cleanly — the proxy stays an
external child process and the case for the rewrite weakens
considerably. Reassess there rather than pushing through.

The specs, plans, and proposals in `specs/` and `workflow/` are
language-agnostic and survive intact. That's what makes this
affordable at all.

**One question that changes the answer:** is Bates for you, or are you
shipping it? If it's yours alone, install friction costs ten minutes a
year and the rewrite costs weeks. If `brew install bates` is meant to
be a thing other people run, start at step 2.

## Porting Inventory

Module-by-module notes for whoever picks this up. File references are
relative to `source/`.

### Configuration

**`lib/bates/config.ex` (406)** — TOML parsing and the application
model. Carries the validation passes: unknown middleware names, cyclic
`depends_on` (via `:digraph`), malformed environment substitution.
`find_by_path/2` resolves a cwd to an application by longest matching
root. Default config path is `~/.config/bates/config.toml`.

Go: `pelletier/go-toml/v2` or `BurntSushi/toml`.

**`lib/bates/service.ex` (23)** — the `Service` struct: `name`,
`command`, `port` (`:auto | integer | nil`), `hostname`, `middleware`,
`depends_on`, `environment`, `addon?`.

Config shorthand worth preserving: a single-service app gets
`hostname = "<name>.test"` implicitly; multi-service apps set
`hostname = true` per service to mean the same thing
(`config.ex:254`).

**`lib/bates/environment.ex` (115)** — user environment substitution.
Recognizes `$NAME`, `${NAME}`, and `$$` as a literal `$`. Unknown
references raise. Merge semantics are `Map.put_new` — existing keys
win. Pure, well tested, mechanical to port.

**`lib/bates/port_number.ex` (7)** — listen on port 0, read the
assigned port, close. Inherently racy (TOCTOU between close and the
child's bind); same in Go, no need to improve it during the port.

### Process Management

**`lib/bates/app.ex` (977)** — the heart. One `GenServer` per
application, holding a per-service state map: `config`,
`assigned_port`, `pid`, `ready`, `started_at`, `exit_status`,
`exports`, `log_buffer`, `closure`.

Behaviors to preserve:

- **Dependency-ordered start** — `:digraph_utils.reachable/2` for the
  closure, `topsort/1` for order (`app.ex:841`). A service is eligible
  to start only when every `depends_on` service reports `up`
  (`app.ex:484`).
- **Readiness** — TCP connect to `127.0.0.1:<port>` every 200 ms
  (`@poll_interval`), timing out at 60 s (`@readiness_timeout`).
  Services with no assigned port are marked ready immediately.
- **Status derivation** — `down`, `starting`, `up`, `crashed`, plus
  `partial` at the application level.
- **Exports** — a service's middleware can emit exports (e.g. the
  PostgreSQL addon emits `PGHOST`/`PGPORT`) which are merged into
  dependents' environments in topological order (`seed_environment/2`).
  `exports_settled` and `addons_settled` are broadcast once the set
  stops changing.
- **Log buffer** — an `:queue` capped at 1,000 lines per service
  (`@max_log_lines`), in memory only, dropped on restart. Drained into
  the crash message when a service dies abnormally.
- **`BATES_APP`** is injected into every child's environment so
  `bates env` invoked from inside a Bates-started process
  short-circuits instead of recursing into the daemon and deadlocking
  against the in-flight start (`app.ex:884`).

**`lib/bates/process_invocation.ex` (19)** — compiles prologue lines
and the command into a single shell string: `prologue; ...; exec
<command>`. This is why middleware can do `source ...` and
`eval "$(direnv export bash)"` — everything runs in one shell.

**`lib/bates/process_supervisor.ex` (72)** — `DynamicSupervisor` plus a
`Registry` keyed by app name. `hostname_lookup/0` builds the
hostname → `{app, service}` map used by the redirect plug.

**Process spawning** — `:exec.run_link(command, [:stdout, :stderr, cd:
root, env: env])` at `app.ex:513`. Stop is `:exec.kill(pid, :sigkill)`
plus a monitor with a 5 s wait (`app.ex:568`).

### Routing

**`lib/bates/caddy.ex` (338)** — the module that disappears if Caddy is
embedded. Current mechanics, for reference during the spike:

- Started as `caddy run --config -` with generated JSON piped to stdin;
  no config file is written to disk.
- Admin API at `http://localhost:2019`; every route carries a stable
  `@id` of `route:<hostname>`; updates are `PATCH /id/<route_id>`.
- Listens on `:443` and `:80`. `tls_connection_policies` sets
  `default_sni` to `bates.test`. TLS automation uses the `internal`
  issuer.
- Three route kinds: one per routable service, one for `bates.test`,
  and a `*.test` catch-all. All start pointed at the control interface.
- **The loading-page mechanism:** a route for a *running* app points at
  the app's port but carries a `handle_response` matching status 502
  that falls back to the control interface. During the window between
  port assignment and the app accepting connections, connection-refused
  502s route to the loading page. This is load-bearing and easy to miss.
- On Caddy crash, restart with fresh config and re-register routes for
  every running app.

DNS is deliberately out of scope. `specs/routing.md` states it plainly:
`/etc/resolver/test` contains `nameserver 127.0.0.1`, and there is no
custom DNS server. Note this contradicts `CLAUDE.md`, which describes
"hooking into DNS resolution to automatically spin up applications on
demand" — that's the original vision, not what was built. On-demand
startup happens through the Caddy catch-all and the control interface,
not DNS. Reconcile `CLAUDE.md` at some point.

### Control Interface

Routes, from `lib/bates_web/router.ex`:

```
GET  /status
GET  /apps/resolve?path=<path>
GET  /processes/:name/logs
POST /processes/:name/start
POST /processes/:name/stop
POST /processes/:name/restart
POST /processes/:name/env
POST /processes/:app/services/:service/start
POST /processes/:app/services/:service/stop
GET  /loading/:app_name/:service_name
GET  /                       (DashboardLive)
GET  /*path                  (FallbackController)
```

The on-demand start flow, end to end:

1. Browser requests `https://myapp.test`.
2. Caddy routes to the control interface (app down) or gets a 502 from
   the app's port (app starting).
3. `BatesWeb.Plugs.AppRedirect` sees a `.test` host that isn't
   `bates.test`, looks it up in `hostname_lookup/0`, and redirects to
   `https://bates.test/loading/<app>/<service>` — or 404s on an unknown
   hostname.
4. `LoadingController` branches on the `Accept` header. `text/html` →
   `LoadingLive` (visible progress, WebSocket-driven redirect when
   ready). Anything else → a blocking request that waits on PubSub.
   `App.up/1` fires on both paths.

**Paused state:** `bates down <app>` marks the app paused so a stray
request doesn't immediately restart it. Paused apps render `PausedLive`
to browsers and return 503 JSON to everything else; `?resume=true`
overrides.

**PubSub topics:** `app:<name>` and `service:<app>:<service>`. The
dashboard subscribes per app; the loading page subscribes to both.

### CLI

`bates setup | status | up [name] | down [name] | restart [name] |
env [name]`. When `name` is omitted it's resolved from cwd via
`/apps/resolve`.

`lib/bates/cli/client.ex` talks HTTPS to `https://bates.test` using the
system trust store (`:public_key.cacerts_get()`), with a 65 s timeout
chosen to sit just outside the 60 s readiness timeout. Transport errors
`:nxdomain` and `{:failed_connect, _}` collapse to the canonical
message `"Bates is not running. Start it with: batesd"`.

`bates setup` writes `/etc/resolver/test` via `sudo tee` (idempotent,
with drift detection) and runs `caddy trust`.

**Design note for the port:** the CLI currently reaches the daemon by
going out through Caddy over HTTPS — to manage the daemon that manages
Caddy. A Unix domain socket, or plain HTTP to the control port on
loopback, would be more robust and would drop the trust-store
dependency from every control command. Worth changing during step 1,
but it changes the JSON API's transport, so decide before porting the
daemon.

## Landmines

Things that will bite a Go port specifically.

**Process groups.** erlexec kills whole process trees. Go's `os/exec`
does not — killing the `sh` wrapper orphans everything it spawned, and
every Bates command runs through a shell wrapper. Set
`SysProcAttr{Setpgid: true}` and signal `-pgid`. This is the single
most likely source of "the app is down but port 3000 is still bound"
bugs.

**Graceful shutdown doesn't exist today.** `stop_service/3` sends
`SIGKILL` directly, with no `SIGTERM` grace period. Rails and Postgres
both deserve better. Fix it during the port rather than reproducing it.

**`$HOME` under sudo.** `config.ex:28` documents using
`System.user_home!/0` specifically so the config path resolves under
`sudo`. Go's `os.UserHomeDir()` just reads `$HOME` and will resolve to
the wrong place. Use `os/user` and honor `SUDO_USER`.

**Test-only registries.** Both `Middleware.Registry` and
`Addons.Registry` branch on `Mix.env() == :test` to expose
`register/2` and `unregister/1`. Replace that compile-time seam with an
injected registry value in Go — don't reach for build tags.

**Middleware validation coupling.** Any service with a `hostname` must
list `"port"` in its middleware, or `build_invocation/3` raises
(`app.ex:862`). It's a runtime raise on start, not a config-load
validation. Consider promoting it to config validation.

**`scrub_path/0` should be deleted, not ported.** It exists solely to
undo the BEAM's own `$PATH` contamination.

## Assets to Reuse

- **`source/test/fixtures/*.toml`** — 22 config fixtures covering
  addons (short form, table form, collisions, duplicates, unknown),
  cyclic dependencies, self-loops, malformed environment values,
  invalid ports, and multi-service shapes. Language-agnostic. Copy them
  verbatim into the Go test corpus.
- **`specs/`** — `system-overview.md`, `process-management.md`,
  `routing.md`, `control-interface.md`, `cli.md`. These describe
  behavior, not implementation, and remain correct through the rewrite.
- **`workflow/proposals/accepted/`** — eleven decision records
  explaining why the current design is what it is. Read before
  "simplifying" anything.
- **`research/`** — `local-dev-servers.md`, `procfile-managers.md`,
  `reverse-proxy.md`.

## Spike Checklist (Step 2)

Timebox: half a day. Success means all five.

1. Embed Caddy (`caddy.Run(cfg)`) or `certmagic` +
   `httputil.ReverseProxy` in a throwaway Go binary.
2. Serve `https://spike.test` on `:443` with an internal-CA
   certificate that the system trust store accepts. Confirm what the
   `caddy trust` equivalent is — Caddy installs its root via
   `smallstep/truststore`; verify that's reachable as a library.
3. Add and remove a route at runtime without restarting the listener.
4. Reproduce the 502 `handle_response` fallback, or find a cleaner
   equivalent (in-process, "is this app up?" is a map lookup — the
   fallback may not need to be a proxy concern at all).
5. Confirm binding `:443` doesn't require root, or determine what it
   does require. Caddy-the-binary handles this today; Caddy-the-library
   inherits the calling process's privileges.

Record the outcome as an experiment under `experiments/`, per CDD.

## Open Questions

- Is Bates for personal use or for distribution? This determines
  whether the rewrite is worth doing at all.
- Should the CLI ↔ daemon transport move to a Unix socket before the
  daemon port? It's cheaper to change once, before there are two
  implementations.
- Is Linux support in scope? It changes the DNS story
  (`/etc/resolver/` is macOS-only; Linux needs `systemd-resolved` or
  dnsmasq) and is a real argument for doing the work now rather than
  bolting it on.
- Does the dashboard need to stay real-time, or would a 1 s polling
  refresh be acceptable? This is the difference between SSE plumbing
  and 20 lines of JavaScript.

## Housekeeping Noticed

Not part of this evaluation, flagged rather than fixed:

- `erl_crash.dump` (3.3 MB) sits untracked in the repo root.
- `.bates/` and `source/.bates/` contain PostgreSQL data directories
  from running Bates against its own checkout. Untracked but not
  gitignored.
- `scrub-env.diff` and `execution.log` are untracked leftovers.
- `source/test/bates_web/live/.dashboard_live_test.exs.swp` is a
  stray Vim swap file.
