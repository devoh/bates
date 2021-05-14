defmodule Conjure.Request do
  use GenServer, restart: :temporary

  alias Conjure.{HTTP, Process}

  defstruct method: nil,
            path: nil,
            version: nil,
            headers: %{},
            body: ""

  # public API

  def start_link(args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  # callbacks

  @impl GenServer
  def init({host, to_socket, %__MODULE__{} = request}) do
    state = %{
      host: host,
      request: request,
      from_socket: nil,
      to_socket: to_socket
    }

    {:ok, state, {:continue, :forward}}
  end

  @impl GenServer
  def handle_continue(
        :forward,
        %{host: host, request: request, to_socket: to_socket} = state
      ) do
    with {:ok, port} = Process.port(host),
         opts <- [:binary, active: false, packet: :raw],
         {:ok, from_socket} <- :gen_tcp.connect('localhost', port, opts) do
      :gen_tcp.send(from_socket, HTTP.request(request))

      {:noreply, %{state | from_socket: from_socket, to_socket: to_socket}, {:continue, :read}}
    else
      # ignore connection errors when server is down
      {:error, reason} when reason in [:econnrefused, :closed] ->
        :ok = :gen_tcp.send(to_socket, HTTP.head(502))
        :ok = :gen_tcp.shutdown(to_socket, :write)
        {:stop, {:shutdown, :normal}, state}

      {:error, :timeout} ->
        :ok = :gen_tcp.send(to_socket, HTTP.head(504))
        :ok = :gen_tcp.shutdown(to_socket, :write)
        {:stop, {:shutdown, :normal}, state}

      error ->
        {:stop, {:shutdown, :normal}, state}
    end
  end

  def handle_continue(:read, %{from_socket: from_socket} = state) do
    :ok = :inet.setopts(from_socket, active: :once)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:tcp, _socket, packet}, %{to_socket: to_socket} = state) do
    :ok = :gen_tcp.send(to_socket, packet)
    {:noreply, state, {:continue, :read}}
  end

  @impl GenServer
  def handle_info({:tcp_closed, _socket}, %{to_socket: to_socket} = state) do
    if to_socket |> :erlang.port_info() |> Keyword.get(:output) == 0,
      do: :ok = :gen_tcp.send(to_socket, HTTP.head(502))

    :ok = :gen_tcp.shutdown(to_socket, :write)

    {:stop, {:shutdown, :closed}, state}
  end

  @impl GenServer
  def handle_info({:tcp_error, socket, reason}, state) do
    IO.inspect(socket, label: "connection closed due to #{reason}")
    {:stop, {:shutdown, reason}, state}
  end
end
