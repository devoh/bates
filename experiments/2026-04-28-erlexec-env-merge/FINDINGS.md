# Findings — erlexec env Option (Merge vs Replace)

**Date:** 2026-04-28
**Assumption:** `:exec.run_link/2`'s `env: [...]` option merges supplied
vars with the inherited environment (vs. replacing the whole env).
**Result:** Merge (with override on collision).

## Test

| Run | Args | Result |
|-----|------|--------|
| 1 | `:exec.run_link(~c"env", [:stdout, :sync])` | ~60 inherited vars (PATH, HOME, USER, SHELL, ASDF_DIR, HOMEBREW_PREFIX, ...). No FOO, no PORT. |
| 2 | `... env: [{~c"FOO", ~c"bar"}]` | All Run 1 vars present, plus `FOO=bar`. |
| 3 | `... env: [{~c"PORT", ~c"5000"}]` | All Run 1 vars present, plus `PORT=5000`. |
| 4 | `sh -c 'echo PATH=$PATH; echo PORT=$PORT'` with `env: [{PORT, 5000}]` | `PATH` resolved from inherited env; `PORT=5000`. |

## Impact on Plan

The plan's approach — passing only middleware-set env vars (e.g. `PORT`)
via erlexec's `env:` option, expecting prologue commands to inherit
`PATH`/`HOME` — is correct. No need to splat `System.get_env()` into the
env option.

## Artifacts

- `explore.exs`
- `raw/output.txt`
