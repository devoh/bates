# Experiment: erlexec + Caddy stdin config delivery
#
# Prove that erlexec can start Caddy with a Caddyfile delivered via
# {stdin, filename} and `caddy run --adapter caddyfile -c -`.
# Caddy should parse the config and start listening.
# We'll use a config that binds to a high port to avoid permission issues.

Mix.install([{:exec, "~> 1.0"}])

{:ok, _} = Application.ensure_all_started(:exec)

caddyfile = """
{
  http_port 19876
  https_port 19877
  local_certs
}

:19876 {
  respond "Hello from Caddy via erlexec stdin!"
}
"""

tmp_path = Path.join(System.tmp_dir!(), "conjure-caddy-test-#{System.unique_integer([:positive])}")
File.write!(tmp_path, caddyfile)

IO.puts("Caddyfile written to: #{tmp_path}")
IO.puts("Starting Caddy with stdin redirect from file...")

case :exec.run_link(
  ~c"caddy run --adapter caddyfile -c -",
  [:stdout, :stderr, :monitor, {:stdin, to_charlist(tmp_path)}]
) do
  {:ok, pid, os_pid} ->
    IO.puts("Caddy started, os_pid=#{os_pid}")

    # Give Caddy a moment to start
    Process.sleep(2000)

    # Try to curl the endpoint
    IO.puts("\nTesting with curl...")
    {curl_output, exit_code} = System.cmd("curl", ["-s", "http://127.0.0.1:19876"], stderr_to_stdout: true)
    IO.puts("curl exit: #{exit_code}")
    IO.puts("curl output: #{curl_output}")

    if curl_output =~ "Hello from Caddy" do
      IO.puts("\nSUCCESS: Caddy read config from stdin via erlexec {stdin, filename}!")
    else
      IO.puts("\nFAILED: Caddy didn't respond as expected")
    end

    # Stop Caddy
    :exec.stop(os_pid)

    receive do
      {:DOWN, ^os_pid, :process, ^pid, status} ->
        IO.puts("Caddy stopped: #{inspect(status)}")
    after
      5000 -> IO.puts("Timeout waiting for Caddy to stop")
    end

  {:error, reason} ->
    IO.puts("FAILED to start Caddy: #{inspect(reason)}")
end

File.rm(tmp_path)
IO.puts("\nDone.")
