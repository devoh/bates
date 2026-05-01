defmodule Bates.CLI.Env do
  @moduledoc false

  @endpoint "https://bates.test"

  def run(name) when is_binary(name) do
    case post_start(name) do
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
        IO.write(:stderr, transport_message(reason) <> "\n")
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

  # HTTP

  defp post_start(name) do
    ensure_apps()
    url = String.to_charlist("#{@endpoint}/processes/#{URI.encode(name)}/start")
    headers = [{~c"accept", ~c"application/json"}]
    request = {url, headers, ~c"application/json", ~c""}
    http_options = [ssl: ssl_options(), timeout: 65_000]

    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _phrase}, _headers, body}} ->
        {:ok, status, decode(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_apps do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp decode(""), do: %{}

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp transport_message({:failed_connect, _}),
    do: "Bates is not running. Start it with: bates start"

  defp transport_message(:nxdomain),
    do: "Bates is not running. Start it with: bates start"

  defp transport_message(reason),
    do: "bates: request failed: #{inspect(reason)}"
end
