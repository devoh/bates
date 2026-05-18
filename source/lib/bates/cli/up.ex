defmodule Bates.CLI.Up do
  @moduledoc false

  alias Bates.CLI.Client

  def run(name) when is_binary(name) do
    case parse(name) do
      {:app, app} -> start_app(app)
      {:service, app, service} -> start_service(app, service)
      :invalid -> invalid_target(name)
    end
  end

  defp parse(name) do
    case String.split(name, ":") do
      [app] when app != "" ->
        {:app, app}

      [app, service] when app != "" and service != "" ->
        {:service, app, service}

      _ ->
        :invalid
    end
  end

  defp start_app(app) do
    case Client.post("/processes/#{URI.encode(app)}/start") do
      {:ok, status, _body} when status in 200..299 ->
        IO.puts("bates: started #{app}")
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

  defp start_service(app, service) do
    path =
      "/processes/#{URI.encode(app)}/services/#{URI.encode(service)}/start"

    case Client.post(path) do
      {:ok, status, _body} when status in 200..299 ->
        IO.puts("bates: started #{app}:#{service}")
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

  defp invalid_target(name) do
    IO.write(
      :stderr,
      "bates up: invalid target #{inspect(name)}; expected <app> or <app>:<service>\n"
    )

    2
  end
end
