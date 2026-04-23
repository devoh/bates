# Experiment: Can erlexec pipe stdin to a child process?
#
# This tests whether :exec.run/2 with the :stdin option can deliver
# content to a process reading from stdin, which is how we plan to
# deliver the Caddyfile to Caddy (`caddy run --adapter caddyfile -c -`).

Mix.install([{:exec, "~> 1.0"}])

# Start the exec application (required for :exec to work)
{:ok, _} = Application.ensure_all_started(:exec)

IO.puts("--- Test 1: Basic stdin piping with cat ---")

# Use `cat` as a simple stdin-reading process
input = "Hello from erlexec stdin!\nLine two.\n"

case :exec.run('cat', [:stdout, :stderr, {:stdin, input}]) do
  {:ok, [{:stdout, output}]} ->
    IO.puts("SUCCESS: cat received stdin and returned:")
    IO.puts(output)

  {:ok, result} ->
    IO.puts("Got result: #{inspect(result)}")

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end

IO.puts("\n--- Test 2: Simulating Caddy-style stdin config ---")

# Simulate a Caddyfile being piped to a process that reads stdin
caddyfile = """
conjure.test {
  reverse_proxy 127.0.0.1:4080
}

myapp.test {
  handle_errors {
    @502 expression `{err.status_code} == 502`
    handle @502 {
      reverse_proxy 127.0.0.1:4080
    }
  }
  reverse_proxy 127.0.0.1:4200
}
"""

case :exec.run('cat', [:stdout, :stderr, {:stdin, caddyfile}]) do
  {:ok, [{:stdout, output}]} ->
    if output == caddyfile do
      IO.puts("SUCCESS: Full Caddyfile content round-tripped through stdin correctly.")
    else
      IO.puts("PARTIAL: Content was delivered but didn't match exactly.")
      IO.puts("Expected #{byte_size(caddyfile)} bytes, got #{byte_size(output)} bytes")
    end

  {:ok, result} ->
    IO.puts("Got result: #{inspect(result)}")

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end

IO.puts("\n--- Test 3: stdin with run_link (how Process.ex uses it) ---")

# Test with run_link since that's what the codebase actually uses
case :exec.run_link('cat', [:stdout, :stderr, {:stdin, caddyfile}]) do
  {:ok, _pid, _os_pid} ->
    receive do
      {:stdout, _pid, output} ->
        IO.puts("SUCCESS via run_link: received #{byte_size(output)} bytes on stdout")
        IO.puts(String.slice(output, 0, 80) <> "...")
    after
      5000 -> IO.puts("TIMEOUT: no stdout received after 5s")
    end

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end

IO.puts("\nDone.")
