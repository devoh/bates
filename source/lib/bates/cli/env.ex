defmodule Bates.CLI.Env do
  @moduledoc false

  alias Bates.CLI.Client

  def run(name) when is_binary(name) do
    if System.get_env("BATES_APP") == name do
      # Already running inside a bates-spawned service for this app — its
      # environment is in scope, so re-invoking the daemon would deadlock
      # against the in-flight start.
      :ok
    else
      request(name)
    end
  end

  defp request(name) do
    case Client.post("/processes/#{URI.encode(name)}/start") do
      {:ok, status, body} when status in 200..299 ->
        announce_started(name, body["status"])

        body
        |> Map.get("exports", %{})
        |> emit_exports()

        :ok

      {:ok, _status, body} ->
        IO.write(:stderr, (body["reason"] || "request failed") <> "\n")
        1

      {:error, reason} ->
        IO.write(:stderr, Client.transport_message(reason) <> "\n")
        1
    end
  end

  defp announce_started(_name, "up"), do: :ok

  defp announce_started(name, _status) do
    IO.write(:stderr, "bates: started #{name}\n")
  end

  @doc false
  def emit_exports(exports) when is_map(exports) do
    exports
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.each(fn {key, value} ->
      IO.puts(format_export(key, value))
    end)
  end

  @doc false
  def format_export(key, value) when is_binary(value) do
    "export #{key}='#{escape(value)}'"
  end

  def format_export(key, value) do
    format_export(key, to_string(value))
  end

  @doc false
  def escape(value) when is_binary(value) do
    String.replace(value, "'", "'\\''")
  end
end
