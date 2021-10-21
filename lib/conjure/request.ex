defmodule Conjure.Request do
  use GenServer, restart: :temporary

  alias Conjure.{HTTP, Process}

  defstruct method: nil,
            path: nil,
            version: nil,
            headers: %{},
            body: ""

  @tld ".test"

  @content_length "content-length"
  @trailer "trailer"
  @transfer_encoding "transfer-encoding"
  @upgrade "upgrade"

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
      encoding: nil,
      length: nil,
      trailer: false,
      from_socket: nil,
      to_socket: to_socket,
      websocket: false
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast(
        :start,
        %{name: name, request: request, to_socket: to_socket} = state
      ) do
    with {:ok, port} = Process.port(name),
         opts <- [:binary, active: false, packet: :http_bin],
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

  @impl GenServer
  def handle_continue(:receive, %{from_socket: from_socket} = state) do
    :ok = :inet.setopts(from_socket, active: :once)
    {:noreply, state}
  end

  @impl GenServer
  def handle_continue(
    :open_websocket,
    %{from_socket: from_socket, to_socket: to_socket} = state
  ) do
    opts = [active: true, packet: 0, nodelay: true]

    :ok = :inet.setopts(to_socket, opts)
    :ok = :inet.setopts(from_socket, opts)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        {:http, _, {:http_response, _, _, _} = data},
        %{to_socket: to_socket} = state
      ) do
    :ok = :gen_tcp.send(to_socket, encode(data))

    {:noreply, state, {:continue, :receive}}
  end

  @impl GenServer
  def handle_info(
        {:http, _, {:http_header, _, _, header, value} = data},
        %{to_socket: to_socket} = state
      ) do
    :ok = :gen_tcp.send(to_socket, encode(data))

    state =
      case String.downcase(header) do
        @content_length -> %{state | length: String.to_integer(value)}
        @trailer -> %{state | trailer: :pending}
        @transfer_encoding -> %{state | encoding: value}
        @upgrade ->
          %{state | websocket: String.downcase(value) == "websocket"}
        _ -> state
      end

    {:noreply, state, {:continue, :receive}}
  end

  @impl GenServer
  def handle_info(
        {:http, _, :http_eoh = data},
      %{to_socket: to_socket, trailer: :read} = state
      ) do
    :ok = :gen_tcp.send(to_socket, encode(data))
    {:stop, {:shutdown, :normal}, state}
  end

  @impl GenServer
  def handle_info(
        {:http, _socket, :http_eoh = data},
        %{to_socket: to_socket, websocket: true} = state
      ) do
    :ok = :gen_tcp.send(to_socket, encode(data))

    {:noreply, state, {:continue, :open_websocket}}
  end

  @impl GenServer
  def handle_info(
        {:http, socket, :http_eoh = data},
        %{encoding: encoding, to_socket: to_socket} = state
      ) do
    :ok = :gen_tcp.send(to_socket, encode(data))

    case encoding do
      "chunked" -> :ok = :inet.setopts(socket, packet: :line)
      _ -> :ok = :inet.setopts(socket, packet: :raw)
    end

    {:noreply, state, {:continue, :receive}}
  end

  @impl GenServer
  def handle_info(
        {:tcp, socket, packet},
        %{encoding: "chunked", trailer: trailer, to_socket: to_socket} = state
      ) do
    :ok = :gen_tcp.send(to_socket, packet)

    length =
      packet
      |> String.trim_trailing("\r\n")
      |> String.to_integer(16)

    # read and forward chunk
    :inet.setopts(socket, packet: :raw)
    {:ok, packet} = :gen_tcp.recv(socket, length + 2) # include \r\n
    :ok = :gen_tcp.send(to_socket, packet)

    case length do
      0 ->
        if trailer do
          :ok = :inet.setopts(socket, packet: :httph_bin)
          {:noreply, %{state | trailer: :read}, {:continue, :receive}}
        else
          {:stop, {:shutdown, :normal}, state}
        end

      _ ->
        # prepare to receive next chunk
        :ok = :inet.setopts(socket, packet: :line)
        {:noreply, state, {:continue, :receive}}
    end
  end

  @impl GenServer
  def handle_info(
        {:tcp, socket, packet},
        %{from_socket: from_socket, to_socket: to_socket, websocket: true} = state
      ) do
    case socket do
      ^from_socket -> :ok = :gen_tcp.send(to_socket, packet)
      ^to_socket -> :ok = :gen_tcp.send(from_socket, packet)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        {:tcp, _, packet},
        %{length: length, to_socket: to_socket} = state
      ) do
    :ok = :gen_tcp.send(to_socket, packet)

    size = String.length(packet)

    if size < length do
      {:noreply, %{state | length: length - size}, {:continue, :receive}}
    else
      :ok = :gen_tcp.shutdown(to_socket, :write)
      {:stop, {:shutdown, :normal}, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp_closed, to_socket}, %{to_socket: to_socket} = state) do
    case :gen_tcp.shutdown(to_socket, :write) do
      :ok -> {:stop, {:shutdown, :closed}, state}
      {:error, reason} -> {:stop, {:shutdown, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(
    {:tcp_closed, from_socket},
    %{from_socket: from_socket, to_socket: to_socket} = state
  ) do
    # respond with 502 if no data has been forwarded yet
    if to_socket |> :erlang.port_info() |> Keyword.get(:output) == 0,
      do: :ok = :gen_tcp.send(from_socket, HTTP.head(502))

    case :gen_tcp.shutdown(from_socket, :write) do
      :ok -> {:stop, {:shutdown, :closed}, state}
      {:error, reason} -> {:stop, {:shutdown, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp_error, socket, reason}, state) do
    IO.inspect(socket, label: "connection closed due to #{reason}")
    {:stop, {:shutdown, reason}, state}
  end

  # helpers

  def encode({:http_response, version, code, text}) do
    version = version |> Tuple.to_list() |> Enum.join(".")
    "HTTP/#{version} #{code} #{text}\r\n"
  end

  def encode({:http_header, _, _, header, value}) do
    "#{header}: #{value}\r\n"
  end

  def encode(:http_eoh) do
    "\r\n"
  end

  defp process_name_from_host(host) do
    String.trim_trailing(host, @tld)
  end
end
