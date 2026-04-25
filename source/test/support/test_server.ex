defmodule Bates.TestServer do
  @moduledoc """
  A minimal TCP server that binds to `$PORT` and responds with HTTP 200 OK.
  Used for manual end-to-end testing of the Bates infrastructure.

  Start with: `elixir test/support/test_server.ex`
  """

  def start(port) do
    {:ok, socket} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :http_bin,
        active: false,
        reuseaddr: true
      ])

    IO.puts("Test server listening on port #{port}")
    accept_loop(socket)
  end

  defp accept_loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    spawn(fn -> handle_client(client) end)
    accept_loop(socket)
  end

  defp handle_client(socket) do
    consume_request(socket)

    response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp consume_request(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, :http_eoh} -> :ok
      {:ok, _} -> consume_request(socket)
      {:error, _} -> :ok
    end
  end
end

if System.get_env("PORT") do
  port = System.get_env("PORT") |> String.to_integer()
  Bates.TestServer.start(port)
end
