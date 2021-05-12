defmodule Conjure.ProcessExec do
  use GenServer, restart: :transient
  require Logger

  alias Conjure.Process

  @port_regex ~r/\$PORT\b/
  @timeout 60_000

  # public API

  def start_link(%Process{} = process) do
    GenServer.start_link(__MODULE__, process, name: via_tuple(process))
  end

  def start(name) do
    GenServer.call(via_tuple(name), :start, @timeout)
  end

  def stop(name) do
    GenServer.stop(via_tuple(name))
  end

  def status(name) do
    GenServer.call(via_tuple(name), :status)
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

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:start, _from, %{process: process} = state) do
    with command <- parse_command(process),
         dir <- process.dir |> Path.expand() |> to_charlist,
         env <- [{'PORT', process.port |> to_charlist}],
         options <- [:stdout, :stderr, cd: dir |> to_charlist, env: env],
         {:ok, pid, _os_pid} <- :exec.run_link(command, options) do
      {:reply, :ok, %{state | pid: pid}}
    else
      error -> {:stop, error, error, state}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, %{pid: pid} = state) do
    {:reply, pid && "running" || "stopped", state}
  end

  @impl GenServer
  def handle_info({stream, _os_pid, data}, %{process: process} = state)
      when stream in [:stdout, :stderr] do
    log process, String.trim(data)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

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

  defp via_tuple(%Process{name: name}) when not is_nil(name),
    do: {:via, Registry, {Conjure.ProcessRegistry, name}}
  defp via_tuple(name) when is_bitstring(name),
    do: {:via, Registry, {Conjure.ProcessRegistry, name}}
end
