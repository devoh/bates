defmodule Bates.CLI.Client do
  @moduledoc false

  @default_base_url "https://bates.test"
  @default_timeout 65_000

  @doc """
  Issues a `GET` request to the running Bates daemon.

  Returns `{:ok, status, body}` with `body` decoded as a map (or `%{}` for
  an empty body), or `{:error, reason}` for transport-level failures.
  """
  def get(path, opts \\ []) do
    request(:get, path, "", opts)
  end

  @doc """
  Issues a `POST` request to the running Bates daemon.

  The body is sent with `Content-Type: application/json`.
  """
  def post(path, body \\ "", opts \\ []) do
    request(:post, path, body, opts)
  end

  @doc false
  def request(method, path, body, opts) do
    ensure_apps()
    url = String.to_charlist("#{base_url()}#{path}")
    headers = [{~c"accept", ~c"application/json"}]
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    request =
      case method do
        :get -> {url, headers}
        :post -> {url, headers, ~c"application/json", to_body(body)}
      end

    http_options = [timeout: timeout] ++ ssl_opts_for(url)

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _phrase}, _headers, response_body}} ->
        {:ok, status, decode(response_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Maps a transport error to a user-facing message.

  `:nxdomain` and `{:failed_connect, _}` collapse to the canonical
  "Bates is not running" message; other errors fall through to a
  diagnostic format.
  """
  def transport_message({:failed_connect, _}), do: not_running_message()
  def transport_message(:nxdomain), do: not_running_message()

  def transport_message(reason),
    do: "bates: request failed: #{inspect(reason)}"

  @doc false
  def not_running_message,
    do: "Bates is not running. Start it with: batesd"

  @doc false
  def ensure_apps do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  @doc false
  def ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp base_url do
    Application.get_env(:bates, :api_base_url, @default_base_url)
  end

  defp ssl_opts_for(url) do
    if List.starts_with?(url, ~c"https://") do
      [ssl: ssl_options()]
    else
      []
    end
  end

  defp to_body(body) when is_binary(body), do: body
  defp to_body(body), do: Jason.encode!(body)

  defp decode(""), do: %{}
  defp decode(nil), do: %{}

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end
end
