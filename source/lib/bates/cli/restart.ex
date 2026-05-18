defmodule Bates.CLI.Restart do
  @moduledoc false

  alias Bates.CLI.Client

  def run(name) when is_binary(name) do
    if String.contains?(name, ":") do
      IO.write(
        :stderr,
        "bates restart does not support per-service form; " <>
          "use 'bates down <app>:<service>' followed by " <>
          "'bates up <app>:<service>'\n"
      )

      2
    else
      restart_app(name)
    end
  end

  defp restart_app(name) do
    case Client.post("/processes/#{URI.encode(name)}/restart") do
      {:ok, status, _body} when status in 200..299 ->
        IO.puts("bates: restarted #{name}")
        :ok

      {:ok, _status, body} ->
        IO.write(
          :stderr,
          (body["error"] || body["reason"] || "request failed") <> "\n"
        )

        1

      {:error, reason} ->
        IO.write(:stderr, Client.transport_message(reason) <> "\n")
        1
    end
  end
end
