# Experiment: erlexec + Caddy — shell redirect approach
#
# {stdin, Filename} gave Caddy an EOF. Try shell redirect instead:
# sh -c 'caddy run --adapter caddyfile -c - < /path/to/file'

Mix.install([{:exec, "~> 1.0"}])

{:ok, _} = Application.ensure_all_started(:exec)

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

IO.puts("Caddyfile at: #{tmp_path}")
IO.puts("Contents:")
IO.puts(caddyfile)

Process.flag(:trap_exit, true)

IO.puts("--- Test 1: Shell redirect ---")

command = ~c"sh -c 'caddy run --adapter caddyfile -c - < #{tmp_path}'"
IO.puts("Command: #{command}")

case :exec.run_link(command, [:stdout, :stderr, :monitor]) do
  {:ok, pid, os_pid} ->
    IO.puts("Started, os_pid=#{os_pid}")

    # Collect messages for a few seconds
    collect = fn loop, n ->
      if n > 15 do
        :ok
      else
        receive do
          {:stderr, ^os_pid, data} ->
            IO.puts("  stderr: #{String.trim(data)}")
            loop.(loop, n + 1)

          {:stdout, ^os_pid, data} ->
            IO.puts("  stdout: #{String.trim(data)}")
            loop.(loop, n + 1)

          {:DOWN, ^os_pid, :process, ^pid, status} ->
            IO.puts("  Exited: #{inspect(status)}")

          {:EXIT, ^pid, reason} ->
            IO.puts("  EXIT: #{inspect(reason)}")
        after
          3000 ->
            IO.puts("  (settled after 3s)")
        end
      end
    end

    collect.(collect, 0)

    # Try curl
    IO.puts("\nTesting with curl...")
    {curl_output, curl_exit} = System.cmd("curl", ["-s", "-m", "2", "http://127.0.0.1:19876"], stderr_to_stdout: true)
    IO.puts("curl exit: #{curl_exit}")
    IO.puts("curl output: #{curl_output}")

    if curl_output =~ "Hello from Caddy" do
      IO.puts("\nSUCCESS!")
    else
      IO.puts("\nCaddy did not respond as expected")
    end

    :exec.stop(os_pid)
    Process.sleep(1000)

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end

IO.puts("\n--- Test 2: Caddy with -c <filename> directly (control) ---")

command2 = ~c"caddy run -c #{tmp_path} --adapter caddyfile"
IO.puts("Command: #{command2}")

case :exec.run_link(command2, [:stdout, :stderr, :monitor]) do
  {:ok, pid2, os_pid2} ->
    IO.puts("Started, os_pid=#{os_pid2}")

    collect2 = fn loop, n ->
      if n > 15 do :ok else
      receive do
        {:stderr, ^os_pid2, data} ->
          IO.puts("  stderr: #{String.trim(data)}")
          loop.(loop, n + 1)
        {:stdout, ^os_pid2, data} ->
          IO.puts("  stdout: #{String.trim(data)}")
          loop.(loop, n + 1)
        {:DOWN, ^os_pid2, :process, ^pid2, status} ->
          IO.puts("  Exited: #{inspect(status)}")
        {:EXIT, ^pid2, reason} ->
          IO.puts("  EXIT: #{inspect(reason)}")
      after
        3000 -> IO.puts("  (settled)")
      end end
    end

    collect2.(collect2, 0)

    IO.puts("\nTesting with curl...")
    {curl_output2, curl_exit2} = System.cmd("curl", ["-s", "-m", "2", "http://127.0.0.1:19876"], stderr_to_stdout: true)
    IO.puts("curl exit: #{curl_exit2}")
    IO.puts("curl output: #{curl_output2}")

    if curl_output2 =~ "Hello from Caddy" do
      IO.puts("\nSUCCESS with -c <file>!")
    end

    :exec.stop(os_pid2)
    Process.sleep(1000)

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end

File.rm(tmp_path)
IO.puts("\nDone.")
