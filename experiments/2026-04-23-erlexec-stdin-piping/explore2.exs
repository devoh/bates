# Experiment: erlexec stdin piping — correct API
#
# erlexec uses :stdin atom to enable the stdin pipe, then :exec.send/2
# to write data, and optionally :exec.send/2 with :eof to close stdin.

Mix.install([{:exec, "~> 1.0"}])

{:ok, _} = Application.ensure_all_started(:exec)

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

IO.puts("--- Test 1: stdin atom + exec.send + cat ---")

case :exec.run(~c"cat", [:stdin, :stdout, :stderr, :monitor]) do
  {:ok, pid, os_pid} ->
    IO.puts("Process started: pid=#{inspect(pid)}, os_pid=#{os_pid}")

    # Send the content to stdin
    :exec.send(os_pid, caddyfile)

    # Close stdin so cat knows we're done
    :exec.send(os_pid, :eof)

    # Collect output
    receive_loop = fn loop, acc ->
      receive do
        {:stdout, ^os_pid, data} ->
          loop.(loop, acc <> data)

        {:DOWN, ^os_pid, :process, ^pid, :normal} ->
          acc
      after
        5000 ->
          IO.puts("TIMEOUT waiting for output")
          acc
      end
    end

    output = receive_loop.(receive_loop, "")

    if output == caddyfile do
      IO.puts("SUCCESS: Caddyfile round-tripped through stdin correctly (#{byte_size(output)} bytes)")
    else
      IO.puts("Output (#{byte_size(output)} bytes):")
      IO.puts(output)
      IO.puts("---")
      IO.puts("Expected (#{byte_size(caddyfile)} bytes):")
      IO.puts(caddyfile)
    end

  {:error, reason} ->
    IO.puts("FAILED to start: #{inspect(reason)}")
end

IO.puts("\n--- Test 2: Simulate Caddy invocation pattern ---")
IO.puts("(Using 'cat -n' to prove stdin was read, like Caddy would read its config)")

case :exec.run(~c"cat -n", [:stdin, :stdout, :stderr, :monitor]) do
  {:ok, pid, os_pid} ->
    :exec.send(os_pid, caddyfile)
    :exec.send(os_pid, :eof)

    receive_loop = fn loop, acc ->
      receive do
        {:stdout, ^os_pid, data} ->
          loop.(loop, acc <> data)

        {:DOWN, ^os_pid, :process, ^pid, :normal} ->
          acc
      after
        5000 -> acc
      end
    end

    output = receive_loop.(receive_loop, "")
    IO.puts("SUCCESS: cat -n output:")
    IO.puts(output)

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end

IO.puts("\nDone.")
