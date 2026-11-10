defmodule Bates.CLI.Info do
  @moduledoc false

  alias Bates.CLI.Client

  def run do
    case Client.resolve_app_by_cwd() do
      {:ok, name} -> run(name)
      {:error, message} -> fail(message)
    end
  end

  def run(name) when is_binary(name) do
    if String.contains?(name, ":") do
      IO.write(
        :stderr,
        "bates info: expected an application name, got #{inspect(name)}\n"
      )

      2
    else
      show(name)
    end
  end

  defp show(name) do
    case Client.get("/status") do
      {:ok, status, body} when status in 200..299 ->
        case Enum.find(body["processes"] || [], &(&1["name"] == name)) do
          nil ->
            fail("unknown application: #{name}")

          app ->
            app |> render() |> IO.write()
            :ok
        end

      {:ok, _status, body} ->
        IO.write(:stderr, Client.error_message(body))
        1

      {:error, reason} ->
        fail(Client.transport_message(reason))
    end
  end

  @doc false
  def render(app) do
    rows =
      Enum.map(app["services"], fn service ->
        [
          service["name"],
          url(service["hostname"]),
          service["status"],
          port(service["port"])
        ]
      end)

    widths =
      rows
      |> Enum.zip_with(& &1)
      |> Enum.map(fn column ->
        column |> Enum.map(&String.length/1) |> Enum.max()
      end)

    table =
      Enum.map(rows, fn row ->
        cells =
          row
          |> Enum.zip(widths)
          |> Enum.map_join("  ", fn {cell, width} ->
            String.pad_trailing(cell, width)
          end)

        "  " <> String.trim_trailing(cells) <> "\n"
      end)

    """
    name:   #{app["name"]}
    root:   #{app["root"]}
    status: #{app["status"]}
    services:
    """ <> Enum.join(table)
  end

  defp url(nil), do: ""
  defp url(hostname), do: "https://" <> hostname

  defp port(nil), do: "—"
  defp port(port), do: to_string(port)

  defp fail(message) do
    IO.write(:stderr, message <> "\n")
    1
  end
end
