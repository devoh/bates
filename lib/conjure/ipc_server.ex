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
         {:ok, response} <- dispatch(data) do
      :gen_tcp.send(socket, packet(response))
    else
      {:error, response} ->
        :gen_tcp.send(socket, packet(response))
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
      %{operation: "up", name: name} ->
        Conjure.Process.up(name)
        |> case do
          :ok -> {:ok, %{status: "success", name: name}}
          _ -> {:error, %{status: "failure", name: name}}
        end

      %{operation: "down", name: name} ->
        Conjure.Process.down(name)
        |> case do
          :ok -> {:ok, %{status: "success", name: name}}
          _ -> {:error, %{status: "failure", name: name}}
        end

      %{operation: "status"} ->
        processes =
          for {name, status} <- Conjure.ProcessSupervisor.status(),
            do: %{name: name, status: status}

        {:ok, %{status: "success", processes: processes}}
    end
  end

  def packet(data) do
    case Jason.encode(data) do
      {:ok, json} -> json <> "\n"
      error -> raise(error)
    end
  end
end
