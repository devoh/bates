# Findings — TOML middleware Parsing

**Date:** 2026-04-28
**Assumption:** `Toml.decode/1` parses `middleware = ["asdf", "port"]` as
a list of strings at both application and service levels, with no
quirks when the key appears at both levels.
**Result:** Confirmed.

## Test

Fixture (`raw/sample.toml`):

```toml
[myapp]
root = "/tmp/myapp"
middleware = ["asdf"]

[myapp.services.web]
command = "bin/rails server"
hostname = true
middleware = ["port"]

[myapp.services.worker]
command = "bin/sidekiq"
```

`Toml.decode/1` returned:

```elixir
{:ok,
 %{
   "myapp" => %{
     "middleware" => ["asdf"],
     "root" => "/tmp/myapp",
     "services" => %{
       "web" => %{
         "command" => "bin/rails server",
         "hostname" => true,
         "middleware" => ["port"]
       },
       "worker" => %{"command" => "bin/sidekiq"}
     }
   }
 }}
```

App-level `middleware` and service-level `middleware` are both plain
lists of binaries. The `worker` service (no `middleware` key) returns
`nil` — no implicit default, no scope merging.

## Impact on Plan

Phase 2 parsing can rely on `Map.get(options, "middleware", [])` at both
levels yielding a list of strings ready to validate against the
registry.

## Artifacts

- `explore.exs`
- `raw/sample.toml`
- `raw/output.txt`
