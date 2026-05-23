defmodule Bates.CLI.Down do
  @moduledoc false

  alias Bates.CLI.Client

  def run do
    case Client.resolve_app_by_cwd() do
      {:ok, name} -> run(name)
      {:error, message} -> resolution_error(message)
    end
  end

  def run(name) when is_binary(name) do
    case parse(name) do
      {:app, app} -> stop_app(app)
      {:service, app, service} -> stop_service(app, service)
      {:cwd_service, service} -> resolve_then_stop_service(service)
      :invalid -> invalid_target(name)
    end
  end

  defp resolve_then_stop_service(service) do
    case Client.resolve_app_by_cwd() do
      {:ok, app} -> stop_service(app, service)
      {:error, message} -> resolution_error(message)
    end
  end

  defp resolution_error(message) do
    IO.write(:stderr, message <> "\n")
    1
  end

  defp parse(name) do
    case String.split(name, ":") do
      [app] when app != "" ->
        {:app, app}

      ["", service] when service != "" ->
        {:cwd_service, service}

      [app, service] when app != "" and service != "" ->
        {:service, app, service}

      _ ->
        :invalid
    end
  end

  defp stop_app(app) do
    case Client.post("/processes/#{URI.encode(app)}/stop") do
      {:ok, status, _body} when status in 200..299 ->
        IO.puts("bates: stopped #{app}")
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

  defp stop_service(app, service) do
    path =
      "/processes/#{URI.encode(app)}/services/#{URI.encode(service)}/stop"

    case Client.post(path) do
      {:ok, status, body} when status in 200..299 ->
        IO.puts(success_line(app, service, body))
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

  defp success_line(app, service, body) do
    base = "bates: stopped #{app}:#{service}"

    case body["cascaded"] do
      cascaded when is_list(cascaded) and cascaded != [] ->
        names = Enum.map(cascaded, & &1["service"]) |> Enum.join(", ")
        "#{base} (also stopped: #{names})"

      _ ->
        base
    end
  end

  defp invalid_target(name) do
    IO.write(
      :stderr,
      "bates down: invalid target #{inspect(name)}; expected <app> or <app>:<service>\n"
    )

    2
  end
end
