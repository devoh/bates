defmodule Conjure.Process do
  use GenServer, restart: :transient
  require Logger

  @enforce_keys [:name, :command, :root]
  defstruct name: "",
            port: 0,
            command: "",
            root: "",
            environment: %{}

  @port_regex ~r/\$PORT\b/
  @timeout 60_000
  @max_log_lines 100
  @poll_interval Application.compile_env(:conjure, :poll_interval, 200)
  @readiness_timeout Application.compile_env(:conjure, :readiness_timeout, 60_000)

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

  def port(name) do
    GenServer.call(via_tuple(name), :port)
  end

  def status(name) do
    GenServer.call(via_tuple(name), :status)
  end

  # callbacks

  @impl GenServer
  def init(%__MODULE__{} = process) do
    Process.flag(:trap_exit, true)

    state = %{
      process: assign_port(process),
      pid: nil,
      ready: false,
      started_at: nil,
      exit_status: nil,
      log_buffer: :queue.new(),
      log_count: 0
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:up, _from, %{process: process, pid: nil} = state) do
    with command <- parse_command(process),
         root <- process.root |> Path.expand() |> to_charlist(),
         env <- env_with_port(process),
         opts <- [:stdout, :stderr, cd: to_charlist(root), env: env],
         {:ok, pid, _os_pid} <- :exec.run_link(command, opts) do
      new_state = %{state | pid: pid, ready: false}
      broadcast(process.name, {:status, "starting"})

      if process.port == 0 do
        new_state = %{new_state | ready: true}
        broadcast(process.name, {:status, "up"})
        {:reply, :ok, new_state}
      else
        Process.send_after(self(), :check_ready, @poll_interval)
        started_at = System.monotonic_time(:millisecond)
        {:reply, :ok, %{new_state | started_at: started_at}}
      end
    else
      error -> {:stop, error, error, state}
    end
  end

  @impl GenServer
  def handle_call(:up, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_call(:down, _from, %{pid: nil} = state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_call(:down, _from, %{process: process, pid: pid} = state) do
    case :exec.stop(pid) do
      :ok ->
        broadcast(process.name, {:status, "down"})
        {:reply, :ok, %{state | pid: nil, ready: false, started_at: nil}}

      error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, %{process: %{port: port}} = state) do
    {:reply, {:ok, port}, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, status_name(state), state}
  end

  @impl GenServer
  def handle_info({stream, _os_pid, data}, %{process: process} = state)
      when stream in [:stdout, :stderr] do
    message = String.trim(data)
    log(process, message)
    {:noreply, buffer_log(state, message)}
  end

  @impl GenServer
  def handle_info(:check_ready, %{pid: pid, ready: false, process: process} = state)
      when not is_nil(pid) do
    case :gen_tcp.connect(~c"127.0.0.1", process.port, [], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        new_state = %{state | ready: true}
        broadcast(process.name, {:status, "up"})
        {:noreply, new_state}

      {:error, _} ->
        elapsed = System.monotonic_time(:millisecond) - state.started_at

        if elapsed >= @readiness_timeout do
          :exec.stop(pid)
          message = "Timed out waiting for port #{process.port}"
          broadcast(process.name, {:status, "crashed", message})
          {:noreply, %{state | pid: nil, ready: false, started_at: nil}}
        else
          Process.send_after(self(), :check_ready, @poll_interval)
          {:noreply, state}
        end
    end
  end

  @impl GenServer
  def handle_info(:check_ready, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:EXIT, _pid, :normal = exit_status}, %{process: process} = state) do
    broadcast(process.name, {:status, "down"})
    {:noreply, %{state | exit_status: exit_status, pid: nil}}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, {:exit_status, exit_status}}, %{process: process} = state) do
    new_state = %{state | exit_status: exit_status, pid: nil}
    log_output = drain_log_buffer(new_state)
    broadcast(process.name, {:status, "crashed", log_output})
    {:noreply, new_state}
  end

  # helpers

  defp assign_port(%__MODULE__{port: 0} = process),
    do: %{process | port: Conjure.PortNumber.next()}

  defp assign_port(process), do: process

  defp broadcast(name, message) do
    Phoenix.PubSub.broadcast(Conjure.PubSub, "process:#{name}", message)
  end

  defp buffer_log(%{log_buffer: buffer, log_count: count} = state, message) do
    if count >= @max_log_lines do
      {_, trimmed} = :queue.out(buffer)
      %{state | log_buffer: :queue.in(message, trimmed)}
    else
      %{state | log_buffer: :queue.in(message, buffer), log_count: count + 1}
    end
  end

  defp drain_log_buffer(%{log_buffer: buffer}) do
    :queue.to_list(buffer) |> Enum.join("\n")
  end

  defp env_with_port(%{environment: environment, port: port}) do
    for {key, value} <- Map.put(environment, "PORT", port),
        into: [],
        do: {to_charlist(key), to_charlist(value)}
  end

  defp log(%__MODULE__{name: name}, message) do
    Logger.info("[#{name}] #{message}")
  end

  defp parse_command(%__MODULE__{command: command, port: port}) do
    Regex.replace(@port_regex, command, port |> to_string()) |> to_charlist()
  end

  defp status_name(%{pid: pid, ready: true}) when not is_nil(pid), do: "up"
  defp status_name(%{pid: pid, ready: false}) when not is_nil(pid), do: "starting"
  defp status_name(%{exit_status: exit}) when exit in [0, nil], do: "down"
  defp status_name(_), do: "crashed"

  defp via_tuple(%__MODULE__{name: name}) when not is_nil(name),
    do: {:via, Registry, {Conjure.ProcessRegistry, name}}

  defp via_tuple(name) when is_bitstring(name),
    do: {:via, Registry, {Conjure.ProcessRegistry, name}}
end
