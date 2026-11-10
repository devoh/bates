defmodule Bates.CLI.Logs do
  @moduledoc false

  alias Bates.CLI.{Client, Target}

  @default_lines 100

  def run(argv) do
    case OptionParser.parse(argv, strict: [lines: :integer]) do
      {opts, args, []} when length(args) <= 1 ->
        lines = Keyword.get(opts, :lines, @default_lines)
        name = List.first(args)

        if lines > 0,
          do: show(Target.resolve(name), name, lines),
          else: usage_error()

      _ ->
        usage_error()
    end
  end

  defp show({:app, app}, _name, lines) do
    request("/processes/#{URI.encode(app)}/logs", lines)
  end

  defp show({:service, app, service}, _name, lines) do
    request(
      "/processes/#{URI.encode(app)}/services/#{URI.encode(service)}/logs",
      lines
    )
  end

  defp show({:error, message}, _name, _lines) do
    IO.write(:stderr, message <> "\n")
    1
  end

  defp show(:invalid, name, _lines) do
    IO.write(
      :stderr,
      "bates logs: invalid target #{inspect(name)}; expected <app> or <app>:<service>\n"
    )

    2
  end

  defp request(path, lines) do
    case Client.get("#{path}?lines=#{lines}") do
      {:ok, status, body} when status in 200..299 ->
        body |> Map.get("services", []) |> render() |> IO.write()
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

  @doc false
  def render([%{"lines" => lines}]), do: Enum.map(lines, &[&1, "\n"])

  def render(services) do
    for %{"name" => name, "lines" => lines} <- services, line <- lines do
      ["[", name, "] ", line, "\n"]
    end
  end

  defp usage_error do
    IO.write(:stderr, "Usage: bates logs [<name>] [--lines <count>]\n")
    2
  end
end
