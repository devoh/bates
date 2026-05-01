# Plan: `bates env` Application Exports

### Revision Log

| Date | What Changed |
|------|--------------|
| 2026-04-30 | Plan created from accepted proposal `2026-04-30-bates-env-application-exports.md`. |
| 2026-04-30 | Readiness audit complete (verdict: READY). All 5 pre-audit open items resolved as non-blocking. Applied minor refinements: explicit timeout on Phase 1 `assert_receive`, sharper Phase 2 race-comment wording, dedicated concurrent-callers Phase 2 test bullet, Phase 3 `:ssl` note. |

## Goal

Ship `bates env <name>` end-to-end: a new `{:exports_settled, exports}`
broadcast on the `"app:<name>"` topic, an extended
`POST /processes/<name>/start` endpoint that blocks until exports
settle and returns them as JSON, and a minimal CLI escript that
formats the response as POSIX `export` lines for use in `.envrc`.

## Proposal

`workflow/proposals/accepted/2026-04-30-bates-env-application-exports.md`

## Why This Matters

The exports machinery (#18) and the postgresql addon (#20) make
`PGHOST`/`PGPORT` available inside the Bates supervision tree, but
nothing outside it can see them. A developer who `cd`s into the app
directory and runs `psql` or `bin/rails c` gets no `$PGPORT`. The
intended path is `direnv` + `eval "$(bates env myapp)"` in `.envrc`.

The wart this plan removes: `direnv` evaluates `.envrc` once on
`cd`-in. If the app is `down` at that moment — the common case, since
Bates is lazy — `bates env` would have nothing to return. The user
would have to run `direnv reload` after the app boots. Extending
`POST /start` to block until exports settle, and triggering boot from
the same call, lets the first `cd`-in produce real values without a
manual reload step.

## Acceptance Criteria

- [x] `Bates.App` broadcasts `{:exports_settled, exports}` on the
      `"app:<name>"` topic exactly once per boot, after every service
      has either spawned (and written its `exports`) or terminal-failed.
- [x] `Bates.App.snapshot/1` returns
      `%{status: status, exports: %{...}, reason: reason}` atomically.
- [x] `POST /processes/:name/start` returns
      `200 {"name": ..., "status": "up", "exports": {...}}` when the
      app is `up` (immediately) or after the boot sequence settles.
- [x] `POST /processes/:name/start` returns
      `422 {"name": ..., "status": "crashed", "reason": "..."}` if a
      service crashes during boot.
- [x] `POST /processes/:name/start` returns
      `504 {"name": ..., "status": "timeout", "reason": "..."}` if the
      60-second wait expires.
- [x] `POST /processes/:name/start` returns
      `404 {"name": ..., "status": "unknown", "reason": "..."}` for an
      unknown application.
- [x] An empty exports map serializes as `"exports": {}` and is a
      success (200), not an error.
- [x] Concurrent `POST /processes/:name/start` calls for a `down` app
      receive the same exports without re-spawning services.
- [x] `mix escript.build` produces a `bates` binary; `bates env <name>`
      formats the JSON exports as `export KEY='value'` lines on stdout
      and exits 0.
- [x] On any non-2xx response (including unknown app, crashed, timeout)
      `bates env` writes the response `reason` to stderr, exits non-zero,
      and emits nothing on stdout.
- [x] On a transport error (server not running) `bates env` writes a
      concise message to stderr, exits non-zero, and emits nothing on
      stdout.
- [x] When the app is not already `up`, `bates env` writes
      `bates: starting <name>...` to stderr on entry. Skipped when the
      app is `up`.
- [x] `specs/cli.md` and `specs/control-interface.md` reflect the new
      contract; no separate `GET /processes/<name>/env` documented.
- [x] `mix test` passes.

---

## Phase 1 — Exports settling in `Bates.App`

Add the `{:exports_settled, exports}` broadcast and a snapshot query.
This is the load-bearing change in the GenServer; everything else
(controller, CLI) consumes its outputs.

### Files

- **Edit:** `source/lib/bates/app.ex`
  - Add `exports_broadcast: false` to the top-level state map in
    `init/1` (around line 72).
  - Add a public `snapshot/1` API:
    ```elixir
    def snapshot(name) do
      GenServer.call(via_tuple(name), :snapshot)
    end
    ```
  - Add the `handle_call(:snapshot, _from, state)` clause:
    ```elixir
    def handle_call(:snapshot, _from, state) do
      {:reply, build_snapshot(state), state}
    end
    ```
  - Reset `exports_broadcast` to `false` at the start of the `:up`
    handler so each fresh boot can re-broadcast:
    ```elixir
    def handle_call(:up, _from, state) do
      state = %{state | exports_broadcast: false}
      new_state = state |> start_eligible() |> maybe_broadcast_exports_settled()
      {:reply, :ok, new_state}
    end
    ```
  - Wrap the existing return points in `start_service/3` (success
    branch, both `assigned_port == nil` and `else`), the
    `:check_ready` timeout branch, and the `:EXIT` handler with
    `maybe_broadcast_exports_settled/1` so the broadcast fires the
    moment all services settle. The cleanest approach is to call it
    once before each `{:noreply, new_state}` or before storing
    `new_state` to be returned; thread it as the last transformation.
  - Add the new helpers near the other private helpers (after
    `derive_status/1` is fine):
    ```elixir
    defp maybe_broadcast_exports_settled(state) do
      if not state.exports_broadcast and all_services_settled?(state) do
        exports = merge_exports(state)
        broadcast_app(state.name, {:exports_settled, exports})
        %{state | exports_broadcast: true}
      else
        state
      end
    end

    defp all_services_settled?(state) do
      Enum.all?(state.services, fn {_name, svc} ->
        svc.pid != nil or svc.exit_status != nil
      end)
    end

    defp merge_exports(state) do
      Enum.reduce(state.services, %{}, fn {_name, svc}, acc ->
        Map.merge(acc, svc.exports)
      end)
    end

    defp build_snapshot(state) do
      status = derive_status(state)
      exports = merge_exports(state)
      reason = crash_reason(state, status)
      %{status: status, exports: exports, reason: reason}
    end

    defp crash_reason(state, "crashed") do
      state.services
      |> Enum.find_value(fn {name, svc} ->
        case svc.exit_status do
          nil -> nil
          :normal -> nil
          status -> "service #{name} failed: #{inspect(status)}"
        end
      end)
    end

    defp crash_reason(_state, _), do: nil
    ```
  - **Settled vs blocked:** a service with a crashed dependency stays
    `pid: nil, exit_status: nil` (it never enters `start_service/3`)
    and so is *not* settled by `all_services_settled?/1`. That's
    intentional — `derive_status/1` returns `"crashed"` in this case
    and the controller's receive loop unblocks on the existing
    `{:status, "crashed", reason}` broadcast, not on
    `:exports_settled`. The broadcast fires only when every service
    has actually run.
- **Edit:** `source/test/bates/app_test.exs`
  - Add a `describe "exports_settled broadcast"` block with cases:
    - A single port-less service produces an empty merged exports
      map and broadcasts `{:exports_settled, %{}}` once after `:up`.
    - A service with a stub middleware that publishes `{"FOO", "bar"}`
      to `exports` produces `{:exports_settled, %{"FOO" => "bar"}}`.
    - Two services with overlapping export keys — last-writer-wins
      by start order.
    - The broadcast fires exactly once across multiple `:up` calls
      on the same app (idempotency check).
    - After `:down` then `:up`, the broadcast fires again for the
      second boot.
  - Subscribe to `"app:<name>"` before calling `App.up/1` in each
    test (mirrors the controller pattern). Use
    `assert_receive {:exports_settled, _}, 5_000` (explicit timeout)
    so a hung broadcast surfaces as a test failure rather than the
    default 100ms ExUnit timeout swallowing it.
  - Reuse `EnvironmentRecorder`/`ExportProducer` stubs from
    `source/test/support/stub_middleware.ex` if they fit the export
    payload needed; otherwise add a small stub.

### Rationale

The new broadcast is the synchronization primitive everything else
depends on. Landing it first with its own tests means Phase 2's
controller change can be authored against a working
`Phoenix.PubSub` contract instead of a hypothetical one.

### Verify

- `mix test source/test/bates/app_test.exs` passes.
- `Phoenix.PubSub.subscribe(Bates.PubSub, "app:testapp")` followed by
  `App.up("testapp")` delivers `{:exports_settled, %{...}}` once.
- Repeating the above without a `:down` does not deliver a second
  `:exports_settled`.

---

## Phase 2 — Extend `POST /processes/:name/start`

Make the start endpoint block until exports settle and return them
in its JSON body. Drop the original "fire and forget" semantics.

### Files

- **Edit:** `source/lib/bates_web/controllers/process_controller.ex`
  - Add a module attribute mirroring the loading controller's
    timeout:
    ```elixir
    @timeout Application.compile_env(:bates, :readiness_timeout, 60_000)
    ```
  - Replace the existing `start/2` action with:
    ```elixir
    def start(conn, %{"name" => name}) do
      case ProcessSupervisor.app_pid(name) do
        nil ->
          conn
          |> put_status(404)
          |> json(%{
            name: name,
            status: "unknown",
            reason: "unknown application: #{name}"
          })

        _pid ->
          Phoenix.PubSub.subscribe(Bates.PubSub, "app:#{name}")
          await_start_response(conn, name)
      end
    end

    defp await_start_response(conn, name) do
      case App.snapshot(name) do
        %{status: "up", exports: exports} ->
          json(conn, %{name: name, status: "up", exports: exports})

        %{status: "crashed", reason: reason} ->
          conn
          |> put_status(422)
          |> json(%{
            name: name,
            status: "crashed",
            reason: reason || "application crashed"
          })

        _ ->
          try do
            App.up(name)
          catch
            :exit, _ -> :ok
          end

          await_settled(conn, name, @timeout)
      end
    end

    defp await_settled(conn, name, timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout
      receive_settled(conn, name, deadline)
    end

    defp receive_settled(conn, name, deadline) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        conn
        |> put_status(504)
        |> json(%{
          name: name,
          status: "timeout",
          reason: "timed out waiting for exports"
        })
      else
        receive do
          {:exports_settled, exports} ->
            json(conn, %{name: name, status: "up", exports: exports})

          {:status, "crashed", reason} ->
            conn
            |> put_status(422)
            |> json(%{name: name, status: "crashed", reason: reason})

          {:status, "crashed"} ->
            conn
            |> put_status(422)
            |> json(%{name: name, status: "crashed", reason: "application crashed"})

          _ ->
            receive_settled(conn, name, deadline)
        after
          remaining ->
            conn
            |> put_status(504)
            |> json(%{
              name: name,
              status: "timeout",
              reason: "timed out waiting for exports"
            })
        end
      end
    end
    ```
  - **Subscribe-before-snapshot** is the race fix from the proposal.
    The order matters: subscribe to `"app:<name>"` *before* calling
    `App.snapshot/1`. If we snapshotted first and the broadcast
    fired between the snapshot read and the subsequent subscribe,
    we would miss the message. With the order flipped, any broadcast
    that fires after subscribe (including ones racing with the
    snapshot read) reaches the controller's mailbox and is caught
    in `receive_settled/3`.
  - **404 lookup helper:** `ProcessSupervisor.app_pid/1` (or
    equivalent) must return `nil` for an unknown application without
    raising. If it doesn't exist yet, add it as a thin wrapper around
    `Process.whereis/1` of the `via_tuple/1` registry name. Prefer
    extending `ProcessSupervisor` over inlining the lookup so the
    controller stays testable.
  - Note: existing tests using `restart` (which currently calls
    `App.down/1` then `App.up/1`) keep working because `restart` is
    not touched.
- **Edit:** `source/lib/bates/process_supervisor.ex`
  - If a `whereis`-style helper isn't already exposed, add:
    ```elixir
    def app_pid(name) do
      case Registry.lookup(Bates.AppRegistry, name) do
        [{pid, _}] -> pid
        [] -> nil
      end
    end
    ```
    (Adjust to whatever the registry pattern in this file actually
    uses; Phase 1 of the survey stopped at `via_tuple/1` references.
    Verify before writing.)
- **Edit:** `source/test/bates_web/controllers/process_controller_test.exs`
  - Add a `describe "start"` block with cases:
    - `POST /processes/<name>/start` against an `up` app returns
      `200 {"name": ..., "status": "up", "exports": {...}}`
      immediately, with the merged exports populated.
    - `POST /processes/<name>/start` against a `down` app triggers
      boot, blocks, and returns the exports once settled (without
      waiting for full TCP readiness — verify by using a service
      with a long-binding port and asserting the response arrives
      before the readiness check would).
    - Empty exports: `{"name": ..., "status": "up", "exports": {}}`
      with a port-less service that produces no exports.
    - Unknown app: 404 + `{"status": "unknown", "reason": "..."}`.
    - Crash during boot: a stub middleware that raises returns 422
      + `{"status": "crashed", "reason": "..."}`.
    - Timeout: configure a small `:readiness_timeout` for the test
      and assert 504 + `{"status": "timeout", ...}`.
    - **Concurrent callers (required, not optional):** spawn two
      `Task.async` calls that both POST against a `down` app
      simultaneously; assert both receive the same exports and the
      app spawns each service exactly once. This is the test that
      proves `App.up/1` idempotency + PubSub fan-out work together.
      Without this test, the concurrency claim in the proposal is
      unsupported.
  - Use the existing `single_service_config/0` pattern (or extend
    it) to produce a fixture with a stub middleware that publishes
    a known export, mirroring `app_test.exs` patterns.

### Rationale

This is the user-facing change. Landing it after Phase 1 means the
controller test suite can rely on the broadcast contract being
already verified, and any flakiness between phases collapses onto
the controller (where the receive loop logic lives).

### Verify

- `mix test source/test/bates_web/controllers/process_controller_test.exs`
  passes.
- `mix test` passes.
- `curl -X POST https://bates.test/processes/<name>/start` (against
  a real running server with an app configured) returns the new JSON
  shape, including the `exports` key.

---

## Phase 3 — CLI escript scaffold + `bates env`

Introduce the `bates` binary just enough to host the `env`
subcommand. Future subcommands (#6) extend the same dispatcher.

### Files

- **Edit:** `source/mix.exs`
  - Add `escript:` to the project keyword list:
    ```elixir
    def project do
      [
        app: :bates,
        version: "0.1.0",
        elixir: "~> 1.14",
        elixirc_paths: elixirc_paths(Mix.env()),
        start_permanent: Mix.env() == :prod,
        deps: deps(),
        escript: [main_module: Bates.CLI, name: "bates"]
      ]
    end
    ```
- **Create:** `source/lib/bates/cli.ex`
  - Module `Bates.CLI`. Top-level dispatcher.
    ```elixir
    defmodule Bates.CLI do
      @moduledoc false

      def main(["env" | rest]), do: Bates.CLI.Env.run(rest)
      def main(_), do: usage()

      defp usage do
        IO.write(:stderr, "Usage: bates env <name>\n")
        System.halt(2)
      end
    end
    ```
  - Keep this file deliberately thin — its job is dispatch and exit
    codes only. New subcommands plug in by adding clauses to
    `main/1` in #6.
- **Create:** `source/lib/bates/cli/env.ex`
  - Module `Bates.CLI.Env`. Handles the `env` subcommand end to end:
    1. Parse args (one positional: app name; bail with usage on
       wrong arity).
    2. Issue a HEAD-or-quick check against the server to determine
       whether the app is already up — actually, simpler: always
       emit the `bates: starting <name>...` line to stderr unless
       we can confirm `up` cheaply. Easiest approach: call
       `GET /status` first, look up the app, suppress the message if
       its status is already `"up"`, otherwise print the message
       before the `POST /start` call.
       (If the cost of two round-trips is unacceptable, fall back to
       always printing the message; the user said "skip when up" but
       it's a UX-only nicety, not a correctness requirement.)
    3. POST `https://bates.test/processes/<name>/start` via `:httpc`
       with `:ssl` configured to use the system trust store.
    4. On 200: parse the JSON body, walk `exports`, write
       `export KEY='VALUE'` lines to stdout (with `'\''` escaping for
       embedded single quotes), exit 0.
    5. On non-2xx: parse JSON, write `body["reason"]` (or the raw
       body if no reason) to stderr, exit 1.
    6. On transport error: write `Bates is not running. Start it
       with: bates start` to stderr, exit 1.
  - Sketch:
    ```elixir
    defmodule Bates.CLI.Env do
      @moduledoc false

      @endpoint "https://bates.test"

      def run([name]) when is_binary(name), do: do_env(name)
      def run(_), do: usage()

      defp do_env(name) do
        maybe_announce_starting(name)

        case post_start(name) do
          {:ok, 200, body} ->
            body |> Map.fetch!("exports") |> emit_exports()
            :ok

          {:ok, _status, body} ->
            IO.write(:stderr, (body["reason"] || "request failed") <> "\n")
            System.halt(1)

          {:error, reason} ->
            IO.write(:stderr, transport_message(reason) <> "\n")
            System.halt(1)
        end
      end

      defp maybe_announce_starting(name) do
        case get_status(name) do
          {:ok, "up"} -> :ok
          _ -> IO.write(:stderr, "bates: starting #{name}...\n")
        end
      end

      defp emit_exports(exports) do
        for {key, value} <- exports do
          IO.puts("export #{key}='#{escape(value)}'")
        end
      end

      defp escape(value), do: String.replace(value, "'", "'\\''")

      defp usage do
        IO.write(:stderr, "Usage: bates env <name>\n")
        System.halt(2)
      end

      # http helpers (httpc + jason) elided
    end
    ```
  - Use `:httpc.request/4` for the POST. Configure SSL with
    `verify: :verify_peer` and `cacerts:` populated by
    `:public_key.cacerts_get/0` (Erlang/OTP 25+; OTP 27 is the
    audit-time version on the dev machine, returning ~158 certs).
    `:ssl` is bundled with `:inets` and is loaded transitively via
    `extra_applications: [:inets]`; no separate addition needed.
    The implementation should still verify HTTPS works end-to-end
    against a real Caddy + bates.test setup before declaring the
    phase done.
- **Create:** `source/test/bates/cli/env_test.exs`
  - Pure unit tests for `Bates.CLI.Env`'s formatting helpers (split
    them out to be testable). No real HTTP. Cases:
    - Single export → one `export KEY='VALUE'` line.
    - Multiple exports → multiple lines.
    - Value with embedded `'` → escaped as `'\''`.
    - Empty exports map → no output.
    - Numeric value (e.g., `52345`) → quoted as a string.
- **Create:** `source/test/bates/cli_test.exs`
  - Top-level dispatcher tests: unknown subcommand → exits 2 with
    usage on stderr (capture with `ExUnit.CaptureIO`).

### Rationale

This is the user's entry point. Putting the escript config and the
dispatcher in this plan (rather than punting to #6) means the proposal
ships something usable on its own. The dispatcher is intentionally
trivial so #6 can extend it without rework.

### Verify

- `mix test` passes (Phase 3's new tests + everything from earlier
  phases).
- `mix escript.build` (run from `source/`) produces a `bates` binary.
- `./bates env <name>` against a live server emits export lines on
  stdout.
- `./bates env unknown-app` writes `unknown application: ...` to
  stderr and exits non-zero.
- `./bates` with no args writes usage to stderr and exits 2.

---

## Phase 4 — Spec updates

Update the user-facing spec files to reflect the new contract.

### Files

- **Edit:** `specs/control-interface.md`
  - **Update lines 113–120** (the `POST /processes/<name>/start`
    block): replace the response shape with:
    ```
    POST bates.test/processes/<name>/start

    → 200
    {
      "name": "myapp",
      "status": "up",
      "exports": {
        "PGHOST": "127.0.0.1",
        "PGPORT": "52345"
      }
    }
    → 422  {"name": "myapp", "status": "crashed", "reason": "..."}
    → 504  {"name": "myapp", "status": "timeout", "reason": "..."}
    → 404  {"name": "myapp", "status": "unknown", "reason": "..."}
    ```
    Add a paragraph below the block: "Blocks until the application's
    services have either spawned (and produced their exports) or
    terminal-failed, up to a 60-second readiness timeout. When the
    app is already `up`, returns immediately. Concurrent callers
    against a `down` app each receive the same merged exports without
    duplicate spawns." Mirror language already used elsewhere in the
    spec.
  - **Delete lines 140–162** (the entire `GET /env` section,
    including the surrounding paragraph). Replace with a brief
    forward reference: "Application exports (e.g., `PGHOST`,
    `PGPORT` from the `postgresql` addon) are returned as part of
    the `POST /processes/<name>/start` response. There is no
    separate env endpoint."
  - At plan time the affected lines are 113–120 (start endpoint) and
    140–162 (env endpoint). Re-grep at execution time before
    editing — the file may have shifted.
- **Edit:** `specs/cli.md`
  - **Update lines 75–114** (the `bates env <name>` section):
    rewrite the description to reflect the new behavior:
    - Triggers boot when the app is `down`; no manual `bates up`
      step required.
    - Blocks until exports settle (process spawn time, before TCP
      readiness).
    - Same `export KEY='value'` output, same `'\''` escaping.
    - Same exit-code contract (0 on success, non-zero on any
      failure with stderr-only output).
    - On cold boot, writes a single `bates: starting <name>...`
      line to stderr so the user sees something is happening.
    - Remove the "Requires the application to be `up`" sentence.
    - Keep the `direnv` example and the `direnv reload` recovery
      paragraph.

### Spec scope

A grep at plan time across `specs/`:

```
grep -rn -E "GET /processes/.*/env|/processes/.*/env|bates env" specs/
```

returns hits only in `specs/cli.md` and `specs/control-interface.md`.
Re-run at execution time; if any other spec has picked up references
to the env endpoint or `bates env`, update them too.

`specs/process-management.md` is intentionally not updated — the new
PubSub broadcast is internal.

### Rationale

Spec is the source of truth. Updating after the code lands lets the
wording reflect the precise final shape (including any small
deviations from this plan).

### Verify

- `grep -rn "GET /processes/.*/env" specs/` returns no results.
- `grep -rn "bates env" specs/` shows the rewritten section in
  `specs/cli.md`.
- The `POST /processes/<name>/start` block in
  `specs/control-interface.md` shows the new response shape.

---

## What Does NOT Change

- Port stability across stop/start cycles (#17). Independent.
- A static-export contract / dry-runnable middleware. Not needed.
- Service-level scoping (`bates env myapp:web`). Deferred.
- Push-based refresh into already-evaluated shells. `direnv reload`
  remains the recovery path.
- Shell flavors beyond bash/zsh.
- Authentication on the endpoint. Localhost-bound; consistent with
  existing endpoints.
- Localhost-only HTTP backdoor or Unix domain socket. HTTPS via
  Caddy is the only transport.
- Spec changes to `specs/process-management.md`.
- Broader CLI subcommands (`status`, `up`, `down`, `restart`).
  Deferred to #6, which extends the dispatcher introduced here.
- The existing `POST /processes/<name>/restart` and
  `POST /processes/<name>/stop` response shapes. Out of scope; only
  `start` changes.

---

## Where to Start

> **Non-authoritative.** These pointers are from the codebase
> survey at plan creation time (2026-04-30). Files may have changed
> by execution time. Verify before acting.

### Core flow to trace

1. `source/lib/bates/app.ex`:
   - `init/1` line 53–73: per-service state shape (`exports: %{}` is
     already there). Add `exports_broadcast: false` to the top-level
     state map at line 72.
   - `handle_call(:up, ...)` line 76–78: where to reset the broadcast
     flag.
   - `start_service/3` line 300–359: success branch sets
     `exports: invocation.exports` at line 321, then broadcasts
     `{:status, "starting"}` at line 328 and (for port-less services
     only) `{:status, "up"}` at line 334. Wrap the state-mutation
     return paths with `maybe_broadcast_exports_settled/1`.
   - `handle_info({:check_ready, ...}, state)` line 137–192: success
     branch (port becomes available) and timeout branch both end with
     `{:noreply, ...}`. Both can settle a service.
   - `handle_info({:EXIT, ...}, state)` line 211–248: a service exits
     here. Settles a previously-non-settled service (one whose
     spawn raced with the exit).
   - `derive_status/1` line 395–406: existing app-level status
     derivation; the new snapshot reuses it.
   - `broadcast_app/2` line 427–429: existing helper for
     `"app:<name>"` topic broadcasts. The new
     `{:exports_settled, exports}` broadcast goes through here.

2. `source/lib/bates_web/controllers/loading_controller.ex` (the
   precedent for subscribe → check → trigger → wait):
   - Lines 8–14: subscribe to PubSub.
   - Lines 16–20: trigger `App.up/1` with `:exit` rescue.
   - Lines 40–53: `await_ready/1` checks current status before
     entering the receive loop — that's the race fix the controller
     mirrors.
   - Lines 55–76: the receive loop with timeout.

3. `source/lib/bates_web/controllers/process_controller.ex`:
   - `start/2` action lines 25–35: the function being replaced.
   - `restart/2` action lines 54–64: shows the existing
     `with`-style two-step pattern; not touched.

4. `source/lib/bates_web/router.ex` line 22: existing route
   definition for `POST /processes/:name/start`. No router change
   needed; only the handler changes.

5. `source/lib/bates/process_supervisor.ex`: contains the
   registry/supervisor for `Bates.App` instances. The 404 path needs
   a way to ask "does an `App` exist for this name?" — verify
   whether such a function already exists; if not, add a small
   helper there rather than inlining into the controller.

### Existing tests to mirror

- `source/test/bates_web/controllers/process_controller_test.exs`:
  the existing `single_service_config/0` and `start_app/1` patterns.
  New tests follow the same shape.
- `source/test/bates/app_test.exs`: lifecycle tests with
  `start_supervised!`, `assert_eventually`, and PubSub
  `assert_receive`. The exports-settled broadcast tests fit here.
- `source/test/support/stub_middleware.ex`: `EnvironmentRecorder`
  and `ExportProducer` stubs reusable for export tests.

### Existing controllers to model

- `BatesWeb.LoadingController` (whole file): subscribe → check →
  trigger → wait pattern.
- `BatesWeb.ProcessController.restart/2`: current shape of an
  endpoint that does a synchronous `App.down/1` then `App.up/1`.

### Existing escript-free elixir CLI patterns

- There is no existing CLI in this repo (`grep -rn "main_module"
  source/mix.exs` returns nothing at plan time). Phase 3 introduces
  the first one. The conventional Elixir escript pattern is:
  - `mix.exs` adds `escript: [main_module: Foo.CLI, name: "foo"]`.
  - `Foo.CLI.main(argv)` is the entry point.
  - `mix escript.build` produces a `./foo` binary.
  - Distribution: copy the binary to `~/.local/bin/` or similar.
  - The escript's HTTP client should use `:inets`/`:httpc` (already
    in `extra_applications`) plus `:jason` for JSON.

### Spec context

- `specs/control-interface.md` lines 113–120 (`POST /start` block)
  and 140–162 (`GET /env` block) are the targets of the spec edits.
- `specs/cli.md` lines 75–114 (`bates env <name>` section).

---

## Readiness Audit

### Audit Log

| Timestamp | Verdict | Summary |
|-----------|---------|---------|
| 2026-04-30 | READY FOR AUTONOMOUS EXECUTION | All assumptions verified against the actual codebase. The 5 pre-audit open items are non-blocking. Minor refinements applied to test guidance and the SSL note in Phase 3. |

### Verdict: READY FOR AUTONOMOUS EXECUTION

All prerequisites exist; all assumptions about line numbers, modules,
test fixtures, and dependencies are confirmed. `/execute-plan` can
proceed without human intervention.

### Input Data

| Input | Status | Notes |
|-------|--------|-------|
| `source/test/support/stub_middleware.ex` | Ready | Contains `ExportProducer` (lines 1–24, registers exports per service via the `:export_producer_exports` app env) and `EnvironmentRecorder` (lines 26–47). Both reusable for the new tests. |
| `source/test/bates/app_test.exs` | Ready | Has the `single_service_config/0` pattern (lines 12–26) and uses `start_supervised!` + `assert_eventually/1` (lines 123, 196). PubSub subscription pattern (lines 6–10) mirrors the new tests' needs. |
| `source/test/bates_web/controllers/process_controller_test.exs` | Ready | Has `single_service_config/0` (lines 6–16) and `start_app/1` (lines 18–21). Test app is `"testapp"` with default hostname `testapp.test`. |
| Spec line numbers | Ready | `specs/control-interface.md` lines 113–120 (POST /start) and 140–162 (GET /env) confirmed; `specs/cli.md` lines 75–114 (bates env section) confirmed. |

### Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `:inets` | Installed | `source/mix.exs` line 18 — `extra_applications: [:logger, :inets]`. Pulls in `:httpc` and `:ssl` transitively. |
| `:jason` | Installed | `source/mix.exs` line 31 — `{:jason, "~> 1.2"}`. |
| `:public_key.cacerts_get/0` | Available | OTP 27 on the dev machine. Returned 158 system trust certs in the audit POC. No fallback to `:certifi` or env var needed. |
| `:ssl` | Available | Bundled with `:inets` via OTP; no separate `extra_applications` entry needed. |
| `Bates.ProcessRegistry` | Installed | `source/lib/bates/application.ex` line 11; `keys: :unique`. The `via_tuple/1` helper at `source/lib/bates/app.ex:557–559` uses `{:via, Registry, {Bates.ProcessRegistry, name}}`. The plan's proposed `ProcessSupervisor.app_pid/1` (Phase 2) wraps `Registry.lookup(Bates.ProcessRegistry, name)` cleanly. |
| `mix escript.build` | Plan covers | Currently fails because no `main_module` is configured — Phase 3 adds it. Expected. |

### Open Questions

| # | Question | Blocking? | Notes |
|---|----------|-----------|-------|
| 1 | `ProcessSupervisor.app_pid/1` shape | No | Resolved. Registry is `Bates.ProcessRegistry` (`source/lib/bates/application.ex:11`); `Registry.lookup/2` returning `[]` for unknown names is the correct `nil` path. Plan's proposed implementation (Phase 2 lines 323–330) is correct as written. |
| 2 | `:public_key.cacerts_get/0` availability | No | Resolved. OTP 27 returns ~158 system certs. No fallback dep needed. Plan's Phase 3 SSL note updated to drop the conditional fallback wording. |
| 3 | `bates env` up-detection round-trip cost | No | Documented as UX-only optimization in plan lines 749–753. Implementation may drop the precheck and always print `bates: starting <name>...` if the extra round-trip is noticeable; it's not a correctness requirement. |
| 4 | Crash detail when multiple services crash | No (deferred) | `crash_reason/2` returns the first non-`:normal` exit. Multi-crash case is an edge case; documented as v1 limitation. |
| 5 | Subscribe-after-up race coverage | No | Resolved via subscribe-then-snapshot pattern (Phase 2). Phase 2's `await_start_response/2` checks the snapshot status *after* subscribing, returning immediately if `up`/`crashed`. The required test for this exact sequence is now folded into Phase 2's test list. |

### POC Gaps

| # | Assumption | Status | Effort |
|---|-----------|--------|--------|
| 1 | PubSub subscription works in a controller process | Confirmed by precedent | quick — `BatesWeb.LoadingController` (production code) already subscribes to `"app:<app_name>"` and receives in the request handler. |
| 2 | All state-mutation return points in `app.ex` are wrapped by `maybe_broadcast_exports_settled/1` | Enumerated | quick — the mutation points are: `start_service/3` line 336 (port-less success), line 349 (port-bearing success); `:check_ready` info handler line 148 (ready) and line 177 (timeout); `:EXIT` info handler line 246. Five sites total, all listed in the plan. |
| 3 | `crash_reason/2` helper compiles | Confirmed | immediate — two function-head clauses, valid Elixir. |
| 4 | `App.up/1` idempotency under concurrent callers | Confirmed by code reading | confirmed — `start_eligible/1` (`app.ex:278–286`) only spawns services where `pid: nil`; `eligible_to_start?` returns false for `pid != nil` services (`app.ex:288–289`). Concurrent `:up` calls re-traverse but spawn nothing already-spawned. |
| 5 | Spec line numbers haven't shifted | Confirmed | quick — `specs/control-interface.md` lines 113–120 and 140–162 contain the expected blocks; `specs/cli.md` lines 75–114 contain the expected `bates env` section. |

### Pre-Work

None. All pre-audit open items are resolved as non-blocking.

### Blockers

None identified.

---

## Execution Notes

- Phase 1 deviated from the plan on the broadcast-flag reset point.
  The plan called for resetting `exports_broadcast: false` at the
  start of the `:up` handler. That broke the "fires exactly once
  across multiple `:up` calls without a `:down` in between" test:
  redundant `:up` calls re-armed the flag and re-broadcast on the
  same already-settled state. Moved the reset into the `:down`
  handler instead, which matches the actual contract ("once per
  boot, where a boot ends at `:down`"). Added a comment at the
  reset site noting why.
- Phase 1 also added a no-op `handle_info({:exports_settled, _}, ...)`
  clause to `BatesWeb.DashboardLive` because the LiveView subscribes
  to `app:<name>` and would otherwise crash on the new message. The
  dashboard does not consume exports yet; the no-op is enough for v1.
- Phase 2's crash and timeout tests both initially returned 200
  because a single port-bearing service with `exit 1` (or a slow
  TCP probe) settles its export state on spawn — *before* the EXIT
  signal (or readiness timeout) arrives. Reworked the fixtures to
  use a two-service config where the second service has
  `depends_on: ["bad"]`. The dependent never enters `start_service/3`
  while its dependency is unsettled, so `all_services_settled?/1`
  stays false and the broadcast doesn't fire prematurely. The
  controller's receive loop then catches the `{:status, "crashed",
  reason}` (or its own `after` timeout) instead of being raced by
  `:exports_settled`. This is exactly the "settled vs blocked"
  distinction the plan called out at lines 163–170, validated by
  the test suite.
- Phase 2 also discovered the controller's wait timeout was
  coupled to `Bates.App`'s readiness timeout because both used the
  same `Application.compile_env(:bates, :readiness_timeout, 60_000)`
  module attribute. The controller couldn't be configured to time
  out *before* `App` did at test runtime. Refactored the controller
  to read its own timeout via runtime `Application.get_env/3` so
  the timeout test can lower the controller's wait without
  reconfiguring `App`'s readiness loop.
- Phase 3 split `Bates.CLI.dispatch/1` from `Bates.CLI.main/1` so
  unit tests can exercise the dispatcher's exit-code contract
  without `System.halt/1` taking down the BEAM. `main/1` is now
  the only place that halts; `dispatch/1` returns either `:ok` or
  an integer. Same pattern applied to `Bates.CLI.Env`.
- Phase 3's HTTP layer uses `:httpc.request/4` with
  `verify: :verify_peer` and `cacerts: :public_key.cacerts_get()`.
  Trust-store lookup is OTP 27-native; no `:certifi` fallback was
  needed.
- Phase 4 spec edits matched the plan's structure cleanly. No
  unrelated specs referenced the removed `GET /env` endpoint.
- Confirmed pre-existing `mix format --check-formatted` failures
  in `process_controller_test.exs`, `app_redirect.ex`, and
  `dashboard_live.ex` predate this branch (verified by checking
  `master`'s copies). Did not fix them in this PR — out of scope.

## Execution Stats

| Metric | Value |
|--------|-------|
| Duration | ~3h |
| Commits | 4 |
| Files changed | 14 |
| Lines | +872 / -54 |
| Tests added | 24 (5 broadcast + 1 snapshot + 7 controller + 11 CLI) |
| Total tests | 174, 0 failures |
| PR | #30 |
