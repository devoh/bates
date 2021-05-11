defmodule Conjure.IPCServer do
  use GenServer

  @path Path.join(System.tmp_dir!, "conjure")

  # public API

  def start_link(_, opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, @path, opts)
  end

  # callbacks

  @impl GenServer
  def init(path) do
    !File.exists?(path) or File.rm(path)

    state = %{
      listen_socket: nil,
      socket: nil,
    }

    opts = [:binary, ifaddr: {:local, path}, active: true, packet: :line]

    case :gen_tcp.listen(0, opts) do
      {:ok, listen_socket} ->
        {:ok, %{state | listen_socket: listen_socket}, {:continue, :accept}}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:accept, %{listen_socket: listen_socket} = state) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    {:noreply, %{state | socket: socket}}
  end

  @impl GenServer
  def handle_info({:tcp, _socket, packet}, %{socket: socket} = state) do
    with {:ok, data} <- Jason.decode(packet, keys: :atoms!),
         {:ok, name} = dispatch(data) do
      :gen_tcp.send(socket, packet(%{status: "success", name: name}))
    else
      {:error, _error} ->
        :gen_tcp.send(socket, packet(%{status: "failure"}))
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:tcp_closed, _socket}, state) do
    {:noreply, state, {:continue, :accept}}
  end

  @impl GenServer
  def handle_info({:tcp_error, socket, reason}, state) do
    IO.inspect(socket, label: "connection closed due to #{reason}")
    {:noreply, state, {:continue, :accept}}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  # helpers

  def dispatch(data) do
    case data do
      %{operation: "add", process: process} ->
        struct(Conjure.Process, process)
        |> Conjure.ProcessSupervisor.add()
        |> case do
          {:ok, _pid} -> {:ok, process.name}
          _ -> :error
        end

      %{operation: "remove", process: process} ->
        struct(Conjure.Process, process)
        |> Conjure.ProcessExec.stop()
        |> IO.inspect(label: "stop")
        |> case do
          :ok -> {:ok, process.name}
          _ -> :error
        end
    end
  end

  def packet(data) do
    case Jason.encode(data) do
      {:ok, json} -> json <> "\n"
      error -> raise(error)
    end
  end
end
