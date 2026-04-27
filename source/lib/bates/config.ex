defmodule Bates.Config do
  alias Bates.Service

  @path "config.toml"

  def applications(path \\ @path) do
    with {:ok, toml} <- File.read(path),
         {:ok, config} <- Toml.decode(toml) do
      Enum.map(config, &build_application/1)
    else
      {:error, :enoent} -> []
      {:error, _} = error -> error
    end
  end

  defp build_application({name, options}) do
    root = Map.fetch!(options, "root")

    services =
      if Map.has_key?(options, "services") do
        build_multi_services(name, options["services"])
      else
        [build_single_service(name, options)]
      end

    {name, root, services}
  end

  defp build_single_service(name, options) do
    %Service{
      name: name,
      command: Map.fetch!(options, "command"),
      port: nil,
      hostname: "#{name}.test"
    }
  end

  defp build_multi_services(app_name, services_map) do
    Enum.map(services_map, fn {service_name, options} ->
      hostname = resolve_hostname(app_name, options["hostname"])
      port = resolve_port(hostname, options["port"])

      %Service{
        name: service_name,
        command: Map.fetch!(options, "command"),
        port: port,
        hostname: hostname,
        middleware: Map.get(options, "middleware", [])
      }
    end)
  end

  defp resolve_hostname(_app_name, nil), do: nil
  defp resolve_hostname(app_name, true), do: "#{app_name}.test"
  defp resolve_hostname(_app_name, value) when is_binary(value), do: "#{value}.test"

  defp resolve_port(_hostname, port) when is_integer(port), do: port
  defp resolve_port(nil, _port), do: nil
  defp resolve_port(_hostname, _port), do: nil
end
