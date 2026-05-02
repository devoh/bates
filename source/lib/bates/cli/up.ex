defmodule Bates.CLI.Up do
  @moduledoc false

  alias Bates.CLI.Client

  def run(name) when is_binary(name) do
    case Client.post("/processes/#{URI.encode(name)}/start") do
      {:ok, status, _body} when status in 200..299 ->
        IO.puts("bates: started #{name}")
        :ok

      {:ok, _status, body} ->
        IO.write(
          :stderr,
          (body["reason"] || body["error"] || "request failed") <> "\n"
        )

        1

      {:error, reason} ->
        IO.write(:stderr, Client.transport_message(reason) <> "\n")
        1
    end
  end
end
