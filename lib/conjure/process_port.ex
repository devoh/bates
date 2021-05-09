defmodule Conjure.ProcessPort do
  use GenServer
  require Logger

  alias Conjure.Process

  @port_regex ~r/\$PORT\b/

  # public API

  def start_link(%Process{} = process, opts \\ []) do
    GenServer.start_link(__MODULE__, process, opts)
  end

  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  def updated(_process) do
  end

  # callbacks

  @impl GenServer
  def init(%Process{} = process) do
    Elixir.Process.flag(:trap_exit, true)

    state = %{
      process: assign_port(process),
      port: nil,
      exit_status: nil,
    }

    {:ok, state, {:continue, :spawn}}
  end

  @impl GenServer
  def handle_continue(:spawn, %{process: %{dir: dir} = process} = state) do
    with {:ok, command, args} <- parse_command(process),
         env <- [{'PORT', process.port |> to_charlist}],
         options <- [:binary, :exit_status, args: args, cd: dir, env: env],
         port <- Port.open({:spawn_executable, command}, options) do
      {:noreply, %{state | port: port}}
    else
      {:not_found, command} -> {:stop, "command not found: #{command}", state}
      reason -> {:stop, reason, state}
    end
  end

  @impl GenServer
  def handle_call(:stop, _from, %{port: port} = state) do
    kill(port)
    #send(port, {self(), :close}) # closing the port doesn’t stop the process, but killing it will result in a message with the exit status
    {:reply, state, %{state | port: nil}}
  end

  @impl GenServer
  def handle_info({_port, {:data, data}}, %{process: process} = state) do
    log process, String.trim(data)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({_port, {:exit_status, status}}, %{process: process} = state) do
    log process, "Exit: #{status}"
    {:noreply, %{state | port: nil, exit_status: status}}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.info "MSG: #{inspect(msg)}"
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: port} = _state) do
    kill(port)
    :ok
  end

  # helpers

  defp assign_port(%Process{port: 0} = process),
    do: %{process | port: Conjure.Daemon.next_port()}
  defp assign_port(process), do: process

  defp kill(port) do
    System.cmd("kill", [os_pid(port) |> to_string()])
  end

  defp log(%Process{name: name}, message) do
    Logger.info("[#{name}] #{message}")
  end

  defp parse_command(%Process{command: command, port: port}) do
    with command <- Regex.replace(@port_regex, command, port |> to_string),
         [command | args] <- command |> String.split(" "),
         path when not is_nil(path) <- System.find_executable(command) do
      {:ok, path, args}
    else
      nil -> {:not_found, command}
    end
  end

  defp os_pid(port) do
    with info when not is_nil(info) <- Port.info(port) do
      Keyword.get(info, :os_pid)
    end
  end
end
