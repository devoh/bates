## Explore: does erlexec :env option MERGE or REPLACE the inherited env?
##
## Run from /Users/thunt/Work/bates/bates/source:
##   mix run --no-start ../experiments/2026-04-28-erlexec-env-merge/explore.exs

# Make sure :exec is started (erlexec)
case :exec.start() do
  {:ok, _pid} -> IO.puts("started :exec")
  {:error, {:already_started, _pid}} -> IO.puts(":exec already started")
  other -> IO.puts("unexpected :exec.start result: #{inspect(other)}")
end

defmodule ExploreEnv do
  @separator String.duplicate("=", 72)

  def run_sync(label, cmd, opts) do
    IO.puts("")
    IO.puts(@separator)
    IO.puts("#{label}")
    IO.puts("cmd: #{inspect(cmd)}")
    IO.puts("opts: #{inspect(opts)}")
    IO.puts(@separator)

    result = :exec.run(cmd, opts)
    IO.puts("result: #{inspect(result, limit: :infinity, printable_limit: :infinity)}")

    stdout =
      case result do
        {:ok, fields} ->
          fields
          |> Keyword.get_values(:stdout)
          |> List.flatten()
          |> Enum.map_join("", &to_string/1)

        _ ->
          ""
      end

    IO.puts("--- stdout ---")
    IO.write(stdout)
    IO.puts("--- end stdout ---")
    stdout
  end

  def grep(stdout, key) do
    stdout
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, key <> "="))
  end

  def summarize(label, stdout) do
    IO.puts("\n[summary: #{label}]")

    for key <- ["PATH", "HOME", "USER", "FOO", "PORT"] do
      matches = grep(stdout, key)
      truncated =
        case matches do
          [] -> "(absent)"
          [line | _] ->
            if String.length(line) > 200 do
              String.slice(line, 0, 200) <> "..."
            else
              line
            end
        end

      IO.puts("  #{key}: #{truncated}")
    end
  end
end

# Run 1: no env opt — baseline inherited env
out1 = ExploreEnv.run_sync(
  "Run 1: env (no :env opt)",
  ~c"env",
  [:stdout, :sync]
)

# Run 2: env merging FOO=bar
out2 = ExploreEnv.run_sync(
  "Run 2: env with env: [{FOO, bar}]",
  ~c"env",
  [:stdout, :sync, {:env, [{~c"FOO", ~c"bar"}]}]
)

# Run 3: PORT only (mirrors the middleware plan)
out3 = ExploreEnv.run_sync(
  "Run 3: env with env: [{PORT, 5000}]",
  ~c"env",
  [:stdout, :sync, {:env, [{~c"PORT", ~c"5000"}]}]
)

# Bonus: prologue-style sh -c invocation
out4 = ExploreEnv.run_sync(
  "Run 4: sh -c 'echo PATH=...; echo HOME=...; echo PORT=...' with PORT=5000",
  ~c"sh -c 'echo PATH=$PATH; echo HOME=$HOME; echo PORT=$PORT'",
  [:stdout, :sync, {:env, [{~c"PORT", ~c"5000"}]}]
)

ExploreEnv.summarize("Run 1 baseline", out1)
ExploreEnv.summarize("Run 2 FOO merged", out2)
ExploreEnv.summarize("Run 3 PORT only", out3)
ExploreEnv.summarize("Run 4 sh prologue", out4)

IO.puts("\n=== verdict ===")

run2_has_path? = ExploreEnv.grep(out2, "PATH") != []
run2_has_foo? = ExploreEnv.grep(out2, "FOO") != []

cond do
  run2_has_path? and run2_has_foo? ->
    IO.puts("MERGE: Run 2 contains both PATH (inherited) and FOO=bar (new).")

  not run2_has_path? and run2_has_foo? ->
    IO.puts("REPLACE: Run 2 only contains FOO=bar; inherited env was discarded.")

  true ->
    IO.puts("INCONCLUSIVE — see raw output.")
end
