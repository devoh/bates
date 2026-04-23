# Experiment: erlexec stdin piping — working approaches
#
# erlexec supports {stdin, Filename} to redirect a file to stdin.
# It also supports :stdin + :exec.send/2 for interactive stdin.
# For Caddy (reads config from stdin, then stays running), we need
# to send content and close stdin. Testing all viable approaches.

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

IO.puts("--- Test 1: {stdin, filename} with temp file ---")

tmp_path = Path.join(System.tmp_dir!(), "conjure-test-caddyfile-#{System.unique_integer([:positive])}")
File.write!(tmp_path, caddyfile)

case :exec.run(~c"cat -n", [:stdout, :stderr, {:stdin, to_charlist(tmp_path)}, {:sync, 5000}]) do
  {:ok, result} ->
    stdout = Keyword.get(result, :stdout, []) |> IO.iodata_to_binary()
    IO.puts("SUCCESS with {stdin, filename}:")
    IO.puts(stdout)

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end

File.rm(tmp_path)

IO.puts("\n--- Test 2: Long-running process with {stdin, filename} ---")
IO.puts("(Simulating Caddy: reads stdin config, then stays running)")

tmp_path2 = Path.join(System.tmp_dir!(), "conjure-test-caddyfile-#{System.unique_integer([:positive])}")
File.write!(tmp_path2, caddyfile)

case :exec.run_link(
  ~c"sh -c 'cat > /dev/null && echo CONFIG_LOADED && sleep 1 && echo STILL_RUNNING'",
  [:stdout, :stderr, :monitor, {:stdin, to_charlist(tmp_path2)}]
) do
  {:ok, pid, os_pid} ->
    IO.puts("Process started, os_pid=#{os_pid}")

    receive_loop = fn loop ->
      receive do
        {:stdout, ^os_pid, data} ->
          IO.puts("  stdout: #{String.trim(data)}")
          loop.(loop)

        {:DOWN, ^os_pid, :process, ^pid, status} ->
          IO.puts("  Process exited: #{inspect(status)}")
      after
        10000 ->
          IO.puts("  TIMEOUT")
      end
    end

    receive_loop.(receive_loop)

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end

File.rm(tmp_path2)

IO.puts("\n--- Test 3: Shell pipe approach (no temp file) ---")

# Embed config in a shell heredoc
# This avoids temp files entirely but embeds config in the command string
escaped = caddyfile |> String.replace("'", "'\\''")
command = ~c"echo '#{escaped}' | cat -n"

case :exec.run(command, [:stdout, :stderr, {:sync, 5000}]) do
  {:ok, result} ->
    stdout = Keyword.get(result, :stdout, []) |> IO.iodata_to_binary()
    IO.puts("SUCCESS with shell pipe:")
    IO.puts(stdout)

  {:error, reason} ->
    IO.puts("FAILED: #{inspect(reason)}")
end

IO.puts("\nDone.")
