defmodule Conjure.Process do
  use GenServer, restart: :transient
  require Logger

  @enforce_keys [:name, :command, :dir]
  defstruct [
    name: "",
    port: 0,
    command: "",
    dir: "",
    env: %{}
  ]

  @port_regex ~r/\$PORT\b/
  @timeout 60_000

  # public API

  def start_link(%__MODULE__{} = process) do
    GenServer.start_link(__MODULE__, process, name: via_tuple(process))
  end

  def up(name) do
    GenServer.call(via_tuple(name), :up, @timeout)
  end

  def down(name) do
    GenServer.call(via_tuple(name), :down, @timeout)
  end

  def status(name) do
    GenServer.call(via_tuple(name), :status)
  end

  # callbacks

  @impl GenServer
  def init(%__MODULE__{} = process) do
    Elixir.Process.flag(:trap_exit, true)

    state = %{
      process: assign_port(process),
      pid: nil,
      exit_status: nil,
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:up, _from, %{process: process} = state) do
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
  def handle_call(:down, _from, %{pid: pid} = state) do
    case :exec.stop(pid) do
      :ok -> {:reply, :ok, %{state | pid: nil}}
      error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, %{pid: pid} = state) do
    {:reply, pid && "up" || "down", state}
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

  defp assign_port(%__MODULE__{port: 0} = process),
    do: %{process | port: Conjure.Daemon.next_port()}
  defp assign_port(process), do: process

  defp log(%__MODULE__{name: name}, message) do
    Logger.info("[#{name}] #{message}")
  end

  defp parse_command(%__MODULE__{command: command, port: port}) do
    Regex.replace(@port_regex, command, port |> to_string()) |> to_charlist()
  end

  defp via_tuple(%__MODULE__{name: name}) when not is_nil(name),
    do: {:via, Registry, {Conjure.ProcessRegistry, name}}
  defp via_tuple(name) when is_bitstring(name),
    do: {:via, Registry, {Conjure.ProcessRegistry, name}}
end
