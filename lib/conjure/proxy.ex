defmodule Conjure.Proxy do
  use GenServer

  alias Conjure.{HTTP, Request}

  @port 42001
  @timeout 500

  @host "Host"
  @content_length "Content-Length"
  @expect "Expect"

  # public API

  def start_link(_, opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, @port, opts)
  end

  # callbacks

  @impl GenServer
  def init(port) do
    Process.flag(:trap_exit, true)

    state = %{
      listen_socket: nil,
      socket: nil,
      host: nil,
      content_length: nil,
      continue: false,
      request: nil
    }

    with opts <- [:binary, active: false, reuseaddr: true],
         {:ok, listen_socket} <- :gen_tcp.listen(port, opts) do
      {:ok, %{state | listen_socket: listen_socket}, {:continue, :accept}}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:accept, %{listen_socket: listen_socket} = state) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    :ok = :inet.setopts(socket, packet: :http_bin)

    {:noreply, %{state | socket: socket, request: %Request{}},
     {:continue, :receive}}
  end

  @impl GenServer
  def handle_continue(:receive, %{socket: socket} = state) do
    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  @impl GenServer
  def handle_continue(
        :forward,
        %{host: host, request: request, socket: socket} = state
      ) do
    {:ok, pid} = Request.start({host, socket, request})
    :ok = :gen_tcp.controlling_process(socket, pid)
    {:noreply, %{state | host: nil, request: nil}, {:continue, :accept}}
  end

  @impl GenServer
  def handle_info(
        {:http, _socket, {:http_request, method, {:abs_path, path}, version}},
        %{request: request} = state
      ) do
    request = %{request | method: method, path: path, version: version}
    {:noreply, %{state | request: request}, {:continue, :receive}}
  end

  @impl GenServer
  def handle_info(
        {:http, _socket, {:http_header, _, _, @host = header, host}},
        state
      ) do
    {:noreply, %{state | host: host} |> put_header(header, host),
     {:continue, :receive}}
  end

  @impl GenServer
  def handle_info(
        {:http, _socket, {:http_header, _, _, @content_length = header, value}},
        state
      ) do
    {:noreply,
     %{state | content_length: String.to_integer(value)}
     |> put_header(header, value), {:continue, :receive}}
  end

  @impl GenServer
  def handle_info(
        {:http, _socket, {:http_header, _, _, @expect, expect}},
        state
      ) do
    {:noreply, %{state | continue: expect == "100-continue"},
     {:continue, :receive}}
  end

  @impl GenServer
  def handle_info(
        {:http, _socket, {:http_header, _, _, header, value}},
        state
      ) do
    {:noreply, put_header(state, header, value), {:continue, :receive}}
  end

  @impl GenServer
  def handle_info(
        {:http, _socket, :http_eoh},
        %{content_length: nil, continue: false} = state
      ) do
    {:noreply, state, {:continue, :forward}}
  end

  @impl GenServer
  def handle_info({:http, socket, :http_eoh}, %{continue: false} = state) do
    {:ok, request} = read_request_body(socket, state)

    {:noreply, %{state | content_length: nil, request: request},
     {:continue, :forward}}
  end

  @impl GenServer
  def handle_info({:http, socket, :http_eoh}, %{continue: true} = state) do
    :ok = :gen_tcp.send(socket, HTTP.head(100))
    {:ok, request} = read_request_body(socket, state)

    {:noreply,
     %{state | content_length: nil, continue: false, request: request},
     {:continue, :forward}}
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

  # helpers

  defp read_request_body(
         socket,
         %{content_length: content_length, request: request}
       ) do
    with :ok = :inet.setopts(socket, packet: :raw),
         {:ok, body} = :gen_tcp.recv(socket, content_length, @timeout) do
      {:ok, %{request | body: body}}
    end
  end

  defp put_header(
         %{request: %{headers: headers} = request} = state,
         header,
         value
       ) do
    %{state | request: %{request | headers: Map.put(headers, header, value)}}
  end
end
