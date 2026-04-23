# Experiment: erlexec 2.x stdin + :eof support
#
# The :exec hex package (1.0.1) doesn't support :exec.send(pid, :eof).
# The :erlexec hex package (2.3.0) is the current release. Test whether
# the newer version supports the send/eof pattern for stdin piping.
#
# Based on sample code:
#   {:ok, _, i} = :exec.run_link("cmd", [:stdin, :stderr])
#   :exec.send(i, data)
#   :exec.send(i, :eof)

Mix.install([{:erlexec, "~> 2.3"}])

{:ok, _} = Application.ensure_all_started(:erlexec)

IO.puts("erlexec version: #{Application.spec(:erlexec, :vsn)}")

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

IO.puts("--- Test 1: send + :eof with cat ---")

{:ok, pid, os_pid} = :exec.run_link(~c"cat", [:stdin, :stdout, :stderr, :monitor])
IO.puts("Started cat, os_pid=#{os_pid}")

:ok = :exec.send(os_pid, caddyfile)
:ok = :exec.send(os_pid, :eof)

receive_loop = fn loop, acc ->
  receive do
    {:stdout, ^os_pid, data} ->
      loop.(loop, acc <> data)

    {:DOWN, ^os_pid, :process, ^pid, :normal} ->
      acc

    {:DOWN, ^os_pid, :process, ^pid, status} ->
      IO.puts("  Unexpected exit: #{inspect(status)}")
      acc
  after
    5000 ->
      IO.puts("  TIMEOUT")
      acc
  end
end

output = receive_loop.(receive_loop, "")

if output == caddyfile do
  IO.puts("SUCCESS: Caddyfile round-tripped (#{byte_size(output)} bytes)")
else
  IO.puts("Output mismatch:")
  IO.puts("  Expected #{byte_size(caddyfile)} bytes, got #{byte_size(output)} bytes")
  IO.puts("  Output: #{inspect(output)}")
end

IO.puts("\n--- Test 2: send + :eof with Caddy ---")

{:ok, pid2, os_pid2} = :exec.run_link(
  ~c"caddy run --adapter caddyfile -c -",
  [:stdin, :stdout, :stderr, :monitor]
)
IO.puts("Started Caddy, os_pid=#{os_pid2}")

:ok = :exec.send(os_pid2, caddyfile)
:ok = :exec.send(os_pid2, :eof)

# Collect Caddy startup messages
collect = fn loop, n ->
  if n > 20 do :ok else
    receive do
      {:stderr, ^os_pid2, data} ->
        IO.puts("  stderr: #{String.trim(data)}")
        loop.(loop, n + 1)

      {:stdout, ^os_pid2, data} ->
        IO.puts("  stdout: #{String.trim(data)}")
        loop.(loop, n + 1)

      {:DOWN, ^os_pid2, :process, ^pid2, status} ->
        IO.puts("  Exited: #{inspect(status)}")
    after
      3000 ->
        IO.puts("  (settled after 3s)")
    end
  end
end

collect.(collect, 0)

# Test with curl
IO.puts("\nTesting with curl on port 19876...")
# Note: the Caddyfile above uses default ports (80/443), so let's check
# if Caddy is actually listening. It may fail due to port permissions.
# Let's just check if it's running and got the config.

# Try the admin API instead
{curl_out, curl_exit} = System.cmd("curl", ["-s", "-m", "2", "http://localhost:2019/config/"], stderr_to_stdout: true)
IO.puts("Admin API (curl exit #{curl_exit}):")
IO.puts(String.slice(curl_out, 0, 200))

# Stop Caddy
:exec.stop(os_pid2)
Process.sleep(500)

IO.puts("\n--- Test 3: Caddy with custom ports via stdin ---")

caddyfile_with_ports = """
{
  http_port 19876
  https_port 19877
}

:19876 {
  respond "Hello from erlexec stdin with eof!"
}
"""

{:ok, pid3, os_pid3} = :exec.run_link(
  ~c"caddy run --adapter caddyfile -c -",
  [:stdin, :stdout, :stderr, :monitor]
)
IO.puts("Started Caddy, os_pid=#{os_pid3}")

:ok = :exec.send(os_pid3, caddyfile_with_ports)
:ok = :exec.send(os_pid3, :eof)

# Wait for startup
Process.sleep(2000)

# Drain messages
flush_msgs = fn loop ->
  receive do
    {:stderr, ^os_pid3, data} ->
      IO.puts("  stderr: #{String.trim(data)}")
      loop.(loop)
    {:stdout, ^os_pid3, data} ->
      IO.puts("  stdout: #{String.trim(data)}")
      loop.(loop)
  after
    100 -> :ok
  end
end

flush_msgs.(flush_msgs)

# Test with curl
IO.puts("\nTesting endpoint...")
{curl_out3, curl_exit3} = System.cmd("curl", ["-s", "-m", "2", "http://127.0.0.1:19876"], stderr_to_stdout: true)
IO.puts("curl exit: #{curl_exit3}")
IO.puts("curl output: #{curl_out3}")

if curl_out3 =~ "Hello from erlexec stdin with eof" do
  IO.puts("\nSUCCESS: Caddy started with config delivered via :exec.send + :eof!")
  IO.puts("No temp files needed.")
else
  IO.puts("\nCaddy did not respond as expected")
end

:exec.stop(os_pid3)
Process.sleep(500)

IO.puts("\nDone.")
