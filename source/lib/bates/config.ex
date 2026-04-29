defmodule Bates.Config do
  alias Bates.{Middleware, Service}

  @path "config.toml"

  def applications(path \\ @path) do
    with {:ok, toml} <- File.read(path),
         {:ok, config} <- Toml.decode(toml) do
      applications = Enum.map(config, &build_application/1)

      with :ok <- validate_middleware(applications),
           :ok <- validate_dependencies(applications) do
        applications
      end
    else
      {:error, :enoent} -> []
      {:error, _} = error -> error
    end
  end

  defp build_application({name, options}) do
    root = Map.fetch!(options, "root")
    app_middleware = Map.get(options, "middleware", [])

    services =
      if Map.has_key?(options, "services") do
        build_multi_services(name, options["services"], app_middleware)
      else
        [build_single_service(name, options, app_middleware)]
      end

    {name, root, services}
  end

  defp build_single_service(name, options, app_middleware) do
    middleware = merge_middleware(app_middleware, [], "#{name}.test")

    %Service{
      name: name,
      command: Map.fetch!(options, "command"),
      port: nil,
      hostname: "#{name}.test",
      middleware: middleware
    }
  end

  defp build_multi_services(app_name, services_map, app_middleware) do
    Enum.map(services_map, fn {service_name, options} ->
      hostname = resolve_hostname(app_name, options["hostname"])
      port = resolve_port(hostname, options["port"])
      service_middleware = Map.get(options, "middleware", [])
      middleware = merge_middleware(app_middleware, service_middleware, hostname)
      depends_on = Map.get(options, "depends_on", [])

      %Service{
        name: service_name,
        command: Map.fetch!(options, "command"),
        port: port,
        hostname: hostname,
        middleware: middleware,
        depends_on: depends_on
      }
    end)
  end

  defp merge_middleware(app_middleware, service_middleware, hostname) do
    merged = app_middleware ++ service_middleware

    if hostname != nil and "port" not in merged do
      merged ++ ["port"]
    else
      merged
    end
  end

  defp resolve_hostname(_app_name, nil), do: nil
  defp resolve_hostname(app_name, true), do: "#{app_name}.test"
  defp resolve_hostname(_app_name, value) when is_binary(value), do: "#{value}.test"

  defp resolve_port(_hostname, port) when is_integer(port), do: port
  defp resolve_port(nil, _port), do: nil
  defp resolve_port(_hostname, _port), do: nil

  defp validate_middleware(applications) do
    Enum.reduce_while(applications, :ok, fn {_name, _root, services}, _acc ->
      case validate_services(services) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_services(services) do
    Enum.reduce_while(services, :ok, fn %Service{middleware: middleware}, _acc ->
      case validate_names(middleware) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_names(names) do
    Enum.reduce_while(names, :ok, fn name, _acc ->
      case Middleware.Registry.lookup(name) do
        {:ok, _module} -> {:cont, :ok}
        {:error, :unknown} -> {:halt, {:error, {:unknown_middleware, name}}}
      end
    end)
  end

  defp validate_dependencies(applications) do
    Enum.reduce_while(applications, :ok, fn {app_name, _root, services}, _acc ->
      with :ok <- validate_dependency_names(app_name, services),
           :ok <- validate_dependency_cycles(app_name, services) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_dependency_names(app_name, services) do
    declared = MapSet.new(services, & &1.name)

    Enum.reduce_while(services, :ok, fn %Service{name: name, depends_on: depends_on}, _acc ->
      case Enum.find(depends_on, &(not MapSet.member?(declared, &1))) do
        nil ->
          {:cont, :ok}

        missing ->
          {:halt, {:error, {:unknown_dependency, app_name, name, missing}}}
      end
    end)
  end

  defp validate_dependency_cycles(app_name, services) do
    graph = :digraph.new()

    try do
      Enum.each(services, fn %Service{name: name} ->
        :digraph.add_vertex(graph, name)
      end)

      Enum.each(services, fn %Service{name: name, depends_on: depends_on} ->
        Enum.each(depends_on, fn dependency ->
          :digraph.add_edge(graph, name, dependency)
        end)
      end)

      case find_cycle(graph, services) do
        nil -> :ok
        cycle -> {:error, {:dependency_cycle, app_name, cycle}}
      end
    after
      :digraph.delete(graph)
    end
  end

  defp find_cycle(graph, services) do
    Enum.find_value(services, fn %Service{name: name} ->
      case :digraph.get_short_cycle(graph, name) do
        false -> nil
        cycle -> normalize_cycle(cycle)
      end
    end)
  end

  defp normalize_cycle([first | _] = cycle) do
    case List.last(cycle) do
      ^first -> Enum.drop(cycle, -1)
      _ -> cycle
    end
  end
end
