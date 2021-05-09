defmodule Conjure.ProcessExec do
  use GenServer
  require Logger

  alias Conjure.Process

  @port_regex ~r/\$PORT\b/

  # public API

  def start_link(%Process{} = process, opts \\ []) do
    GenServer.start_link(__MODULE__, process, opts)
  end

  def updated(_process) do
  end

  # callbacks

  @impl GenServer
  def init(%Process{} = process) do
    Elixir.Process.flag(:trap_exit, true)

    state = %{
      process: assign_port(process),
      pid: nil,
      exit_status: nil,
    }

    {:ok, state, {:continue, :exec}}
  end

  @impl GenServer
  def handle_continue(:exec, %{process: %{dir: dir} = process} = state) do
    with command <- parse_command(process),
         env <- [{'PORT', process.port |> to_charlist}],
         options <- [:stdout, :stderr, cd: dir |> to_charlist, env: env],
         {:ok, pid, _os_pid} <- :exec.run_link(command, options) do
      {:noreply, %{state | pid: pid}}
    else
      {:not_found, command} -> {:stop, "command not found: #{command}", state}
      reason -> {:stop, reason, state}
    end
  end

  @impl GenServer
  def handle_info({stream, _os_pid, data}, %{process: process} = state)
      when stream in [:stdout, :stderr] do
    log process, String.trim(data)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.info "MSG: #{inspect(msg)}"
    {:noreply, state}
  end

  # helpers

  defp assign_port(%Process{port: 0} = process),
    do: %{process | port: Conjure.Daemon.next_port()}
  defp assign_port(process), do: process

  defp log(%Process{name: name}, message) do
    Logger.info("[#{name}] #{message}")
  end

  defp parse_command(%Process{command: command, port: port}) do
    Regex.replace(@port_regex, command, port |> to_string()) |> to_charlist()
  end
end
