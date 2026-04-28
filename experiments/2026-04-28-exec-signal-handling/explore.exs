# Experiment: Does shell `exec` actually replace the shell process when
# erlexec wraps a `sh -c` command, so signals reach the final command?
#
# We test:
#   1. With `exec`: `sh -c 'echo started; exec sleep 30'`
#   2. Without:     `sh -c 'echo started; sleep 30'`
#
# For each case we check:
#   - What command the returned os_pid actually maps to (via `ps`).
#   - Whether the os_pid has children (via `pgrep -P`).
#   - Whether SIGTERM via :exec.kill terminates the process cleanly.

# Trap exits so the linked erlexec child terminating doesn't bring the script
# down. We *want* to observe its exit status as a message, not as our own exit.
Process.flag(:trap_exit, true)

# Ensure :exec is started.
case Application.ensure_all_started(:erlexec) do
  {:ok, _} -> IO.puts("erlexec application started")
  err -> IO.puts("erlexec ensure_all_started returned: #{inspect(err)}")
end

# Some versions register the application as :exec rather than :erlexec.
# Try :exec.start/0 too as a belt-and-suspenders approach.
try do
  case :exec.start() do
    {:ok, _pid} -> IO.puts(":exec.start/0 -> ok")
    {:error, {:already_started, _pid}} -> IO.puts(":exec.start/0 -> already_started")
    other -> IO.puts(":exec.start/0 -> #{inspect(other)}")
  end
rescue
  e -> IO.puts(":exec.start/0 raised: #{inspect(e)}")
end

defmodule Probe do
  def ps(os_pid) do
    case System.cmd("ps", ["-o", "pid,command", "-p", "#{os_pid}"], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> "ps exited #{code}: #{out}"
    end
  end

  def children(os_pid) do
    case System.cmd("pgrep", ["-P", "#{os_pid}"], stderr_to_stdout: true) do
      {"", 1} -> "(none)"
      {out, 0} -> String.trim(out)
      {out, code} -> "pgrep exited #{code}: #{out}"
    end
  end

  def child_command(child_pid) do
    case System.cmd("ps", ["-o", "pid,command", "-p", "#{child_pid}"], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> "ps exited #{code}: #{out}"
    end
  end

  def alive?(os_pid) do
    case System.cmd("ps", ["-p", "#{os_pid}"], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, _} -> false
    end
  end

  def drain_messages(timeout_ms \\ 100) do
    receive do
      msg ->
        IO.puts("  msg: #{inspect(msg)}")
        drain_messages(timeout_ms)
    after
      timeout_ms -> :ok
    end
  end

  def run_case(label, command_charlist) do
    IO.puts("\n=========================================================")
    IO.puts("CASE: #{label}")
    IO.puts("CMD : #{inspect(command_charlist)}")
    IO.puts("=========================================================")

    case :exec.run_link(command_charlist, [:stdout, :stderr]) do
      {:ok, pid, os_pid} ->
        IO.puts("erlexec pid : #{inspect(pid)}")
        IO.puts("os_pid      : #{os_pid}")

        # Wait for the shell to (potentially) exec into sleep.
        Process.sleep(500)

        # What is os_pid actually running right now?
        IO.puts("\n--- ps -o pid,command -p #{os_pid} ---")
        IO.puts(ps(os_pid))

        # Any children?
        IO.puts("--- pgrep -P #{os_pid} ---")
        kids = children(os_pid)
        IO.puts(kids)

        if kids != "(none)" do
          for kid <- String.split(kids, "\n", trim: true) do
            IO.puts("--- ps for child #{kid} ---")
            IO.puts(child_command(kid))
          end
        end

        # Send SIGTERM.
        IO.puts("\n--- sending SIGTERM via :exec.kill(pid, 15) ---")
        kill_result = :exec.kill(pid, 15)
        IO.puts("kill result: #{inspect(kill_result)}")

        # Wait up to ~1s for an exit message.
        t0 = System.monotonic_time(:millisecond)
        exit_status =
          receive do
            {:DOWN, _, :process, _, reason} -> {:down, reason}
            {:EXIT, _, reason} -> {:exit, reason}
            other -> {:other, other}
          after
            1500 -> :timeout
          end
        elapsed = System.monotonic_time(:millisecond) - t0
        IO.puts("exit signal received after #{elapsed}ms: #{inspect(exit_status)}")

        Process.sleep(200)
        still_alive = alive?(os_pid)
        IO.puts("os_pid #{os_pid} still alive after kill: #{still_alive}")

        IO.puts("--- draining other erlexec messages ---")
        drain_messages(200)

      {:error, reason} ->
        IO.puts("run_link FAILED: #{inspect(reason)}")
    end
  end
end

Probe.run_case(
  "WITH exec prefix",
  ~c"sh -c 'echo started; exec sleep 30'"
)

Probe.run_case(
  "WITHOUT exec prefix",
  ~c"sh -c 'echo started; sleep 30'"
)

IO.puts("\nDone.")
