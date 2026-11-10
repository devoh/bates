defmodule Bates.CLI.Up do
  @moduledoc false

  alias Bates.CLI.{Client, Target}

  def run(name \\ nil) do
    case Target.resolve(name) do
      {:app, app} -> start_app(app)
      {:service, app, service} -> start_service(app, service)
      {:error, message} -> resolution_error(message)
      :invalid -> invalid_target(name)
    end
  end

  defp resolution_error(message) do
    IO.write(:stderr, message <> "\n")
    1
  end

  defp start_app(app) do
    case Client.post("/processes/#{URI.encode(app)}/start") do
      {:ok, status, _body} when status in 200..299 ->
        IO.puts("bates: started #{app}")
        :ok

      {:ok, _status, body} ->
        IO.write(:stderr, Client.error_message(body))

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
        IO.write(:stderr, Client.error_message(body))

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
