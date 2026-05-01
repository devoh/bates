defmodule Bates.CLI.Env do
  @moduledoc false

  @endpoint "https://bates.test"

  def run([name]) when is_binary(name), do: do_env(name)
  def run(_), do: usage()

  defp do_env(name) do
    maybe_announce_starting(name)

    case post_start(name) do
      {:ok, status, body} when status in 200..299 ->
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

  defp maybe_announce_starting(name) do
    case get_status(name) do
      {:ok, "up"} -> :ok
      _ -> IO.write(:stderr, "bates: starting #{name}...\n")
    end
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

  defp usage do
    IO.write(:stderr, "Usage: bates env <name>\n")
    2
  end

  # HTTP

  defp post_start(name) do
    request("#{@endpoint}/processes/#{URI.encode(name)}/start", :post)
  end

  defp get_status(name) do
    case request("#{@endpoint}/status", :get) do
      {:ok, status, body} when status in 200..299 ->
        process =
          (body["processes"] || [])
          |> Enum.find(fn proc -> proc["name"] == name end)

        if process, do: {:ok, process["status"]}, else: :error

      _ ->
        :error
    end
  end

  defp request(url, method) do
    ensure_apps()
    url_charlist = String.to_charlist(url)
    headers = [{~c"accept", ~c"application/json"}]

    request_tuple =
      case method do
        :post -> {url_charlist, headers, ~c"application/json", ~c""}
        :get -> {url_charlist, headers}
      end

    http_options = [
      ssl: ssl_options(),
      timeout: 65_000
    ]

    case :httpc.request(method, request_tuple, http_options,
           body_format: :binary
         ) do
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
