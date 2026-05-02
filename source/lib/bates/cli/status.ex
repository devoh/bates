defmodule Bates.CLI.Status do
  @moduledoc false

  alias Bates.CLI.Client

  @headers ["NAME", "HOSTNAME", "STATUS", "PORT"]
  @indent "  "
  @null "—"

  def run do
    case Client.get("/status") do
      {:ok, status, body} when status in 200..299 ->
        body
        |> Map.get("processes", [])
        |> render()
        |> IO.write()

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
  def render(processes) when is_list(processes) do
    rows = [@headers | Enum.flat_map(processes, &process_rows/1)]
    widths = column_widths(rows)
    Enum.map_join(rows, "\n", &format_row(&1, widths)) <> "\n"
  end

  defp process_rows(%{"name" => name, "services" => [only]} = process) do
    [
      [
        name,
        hostname_to_string(only["hostname"]),
        Map.get(only, "status", Map.get(process, "status", "")),
        port_to_string(only["port"])
      ]
    ]
  end

  defp process_rows(%{"name" => name, "services" => services} = process) do
    parent = [name, "", Map.get(process, "status", ""), ""]

    children =
      Enum.map(services, fn svc ->
        [
          @indent <> Map.get(svc, "name", ""),
          hostname_to_string(svc["hostname"]),
          Map.get(svc, "status", ""),
          port_to_string(svc["port"])
        ]
      end)

    [parent | children]
  end

  defp hostname_to_string(nil), do: ""
  defp hostname_to_string(value) when is_binary(value), do: value

  defp port_to_string(nil), do: @null
  defp port_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp port_to_string(value) when is_binary(value), do: value

  defp column_widths(rows) do
    Enum.reduce(rows, [0, 0, 0, 0], fn row, acc ->
      Enum.zip_with(row, acc, fn cell, max ->
        max(String.length(to_string(cell)), max)
      end)
    end)
  end

  defp format_row(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join("", fn {cell, width} -> pad(cell, width) end)
    |> String.trim_trailing()
  end

  defp pad(cell, width) do
    cell = to_string(cell)
    padding = max(width - String.length(cell), 0)
    cell <> String.duplicate(" ", padding) <> "   "
  end
end
