defmodule Conjure.Request do
  use GenServer, restart: :temporary

  alias Conjure.{HTTP, Process}

  defstruct method: nil,
            path: nil,
            version: nil,
            headers: %{},
            body: ""

  @tld ".test"
  @content_length :"Content-Length"

  # public API

  def start(args, opts \\ []) do
    GenServer.start(__MODULE__, args, opts)
  end

  # callbacks

  @impl GenServer
  def init({host, to_socket, %__MODULE__{} = request}) do
    state = %{
      name: process_name_from_host(host),
      request: request,
      length: nil,
      from_socket: nil,
      to_socket: to_socket
    }

    {:ok, state, {:continue, :forward}}
  end

  @impl GenServer
  def handle_continue(
        :forward,
        %{name: name, request: request, to_socket: to_socket} = state
      ) do
    with {:ok, port} = Process.port(name),
         opts <- [:binary, active: false],
         {:ok, from_socket} <- :gen_tcp.connect('127.0.0.1', port, opts) do
      :gen_tcp.send(from_socket, HTTP.request(request))

      {:noreply, %{state | from_socket: from_socket, to_socket: to_socket},
       {:continue, :receive}}
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

      {:error, reason} ->
        {:stop, {:shutdown, reason}, state}
    end
  end

  def handle_continue(:receive, %{from_socket: from_socket} = state) do
    :ok = :inet.setopts(from_socket, active: :once)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        {:tcp, _socket, packet},
        %{length: nil, to_socket: to_socket} = state
      ) do
    case decode_response(packet) do
      {:ok, headers, body} ->
        length = headers |> Keyword.get(@content_length) |> String.to_integer()
        send_packet(packet, String.length(body), %{state | length: length})

      {:error, error} ->
        :ok = :gen_tcp.shutdown(to_socket, :write)
        {:stop, {:shutdown, error}, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp, _socket, packet}, state) do
    send_packet(packet, state)
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

  # helpers

  defp decode_response(packet) do
    case :erlang.decode_packet(:http_bin, packet, []) do
      {:ok, {:http_response, _version, _status, _message}, rest} ->
        decode_headers(rest)

      {:error, error} ->
        {:error, error}
    end
  end

  defp decode_headers(packet, headers \\ []) do
    case :erlang.decode_packet(:httph_bin, packet, []) do
      {:ok, {:http_header, _len, field, _res, value}, rest} ->
        decode_headers(rest, [{field, value} | headers])

      {:ok, :http_eoh, body} ->
        {:ok, headers, body}
    end
  end

  defp process_name_from_host(host) do
    String.trim_trailing(host, @tld)
  end

  defp send_packet(packet, state) do
    size = String.length(packet)
    send_packet(packet, size, state)
  end

  defp send_packet(
         packet,
         size,
         %{length: length, to_socket: to_socket} = state
       ) do
    :ok = :gen_tcp.send(to_socket, packet)

    if size < length do
      {:noreply, %{state | length: length - size}, {:continue, :receive}}
    else
      :ok = :gen_tcp.shutdown(to_socket, :write)
      {:stop, {:shutdown, :normal}, state}
    end
  end
end
