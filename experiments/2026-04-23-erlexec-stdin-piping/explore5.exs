# Experiment: erlexec + Caddy — capture stderr for diagnostics

Mix.install([{:exec, "~> 1.0"}])

{:ok, _} = Application.ensure_all_started(:exec)

# First verify the Caddyfile is valid by running caddy fmt
caddyfile = """
{
  http_port 19876
  https_port 19877
}

:19876 {
  respond "Hello from Caddy via erlexec stdin!"
}
"""

tmp_path = Path.join(System.tmp_dir!(), "conjure-caddy-test-#{System.unique_integer([:positive])}")
File.write!(tmp_path, caddyfile)

IO.puts("--- Validating Caddyfile with caddy adapt ---")
{output, exit_code} = System.cmd("sh", ["-c", "cat #{tmp_path} | caddy adapt --adapter caddyfile 2>&1"])
IO.puts("Exit: #{exit_code}")
IO.puts("Output: #{String.slice(output, 0, 500)}")

IO.puts("\n--- Starting Caddy via erlexec ---")

# Use Process.flag to trap exits so we can capture the error
Process.flag(:trap_exit, true)

case :exec.run_link(
  ~c"caddy run --adapter caddyfile -c -",
  [:stdout, :stderr, :monitor, {:stdin, to_charlist(tmp_path)}]
) do
  {:ok, pid, os_pid} ->
    IO.puts("Caddy started, os_pid=#{os_pid}")

    receive_loop = fn loop, n ->
      if n > 20 do
        IO.puts("Max iterations reached")
      else
        receive do
          {:stderr, ^os_pid, data} ->
            IO.puts("  stderr: #{String.trim(data)}")
            loop.(loop, n + 1)

          {:stdout, ^os_pid, data} ->
            IO.puts("  stdout: #{String.trim(data)}")
            loop.(loop, n + 1)

          {:DOWN, ^os_pid, :process, ^pid, status} ->
            IO.puts("  Process exited: #{inspect(status)}")

          {:EXIT, ^pid, reason} ->
            IO.puts("  EXIT: #{inspect(reason)}")

          other ->
            IO.puts("  other: #{inspect(other)}")
            loop.(loop, n + 1)
        after
          3000 ->
            IO.puts("  (no more messages after 3s)")

            # Try curl
            IO.puts("\nTesting with curl...")
            {curl_output, curl_exit} = System.cmd("curl", ["-s", "-m", "2", "http://127.0.0.1:19876"], stderr_to_stdout: true)
            IO.puts("curl exit: #{curl_exit}, output: #{curl_output}")

            :exec.stop(os_pid)
        end
      end
    end

    receive_loop.(receive_loop, 0)

  {:error, reason} ->
    IO.puts("FAILED to start: #{inspect(reason)}")
end

File.rm(tmp_path)
IO.puts("\nDone.")
