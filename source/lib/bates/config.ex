defmodule Bates.Config do
  alias Bates.{Addons, Middleware, Service}

  @path "config.toml"

  def applications(path \\ @path) do
    with {:ok, toml} <- File.read(path),
         {:ok, config} <- Toml.decode(toml),
         {:ok, applications} <- build_applications(config),
         :ok <- validate_middleware(applications),
         :ok <- validate_dependencies(applications) do
      applications
    else
      {:error, :enoent} -> []
      {:error, _} = error -> error
    end
  end

  defp build_applications(config) do
    Enum.reduce_while(config, {:ok, []}, fn entry, {:ok, acc} ->
      case build_application(entry) do
        {:ok, application} -> {:cont, {:ok, acc ++ [application]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp build_application({name, options}) do
    root = Map.fetch!(options, "root")
    app_middleware = Map.get(options, "middleware", [])
    addon_names = parse_addons(Map.get(options, "addons"))

    with {:ok, services} <- build_services(name, options, app_middleware),
         {:ok, expanded} <-
           expand_addons(name, services, addon_names, app_middleware) do
      {:ok, {name, root, expanded}}
    end
  end

  defp build_services(name, options, app_middleware) do
    if Map.has_key?(options, "services") do
      build_multi_services(name, options["services"], app_middleware)
    else
      {:ok, [build_single_service(name, options, app_middleware)]}
    end
  end

  defp parse_addons(nil), do: []
  defp parse_addons(names) when is_list(names), do: names

  defp parse_addons(map) when is_map(map) do
    map |> Map.keys() |> Enum.sort()
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
    Enum.reduce_while(services_map, {:ok, []}, fn {service_name, options},
                                                  {:ok, acc} ->
      case resolve_port(options["port"]) do
        {:ok, port} ->
          hostname = resolve_hostname(app_name, options["hostname"])
          service_middleware = Map.get(options, "middleware", [])

          middleware =
            merge_middleware(app_middleware, service_middleware, hostname)

          depends_on = Map.get(options, "depends_on", [])

          service = %Service{
            name: service_name,
            command: Map.fetch!(options, "command"),
            port: port,
            hostname: hostname,
            middleware: middleware,
            depends_on: depends_on
          }

          {:cont, {:ok, acc ++ [service]}}

        {:error, value} ->
          {:halt, {:error, {:invalid_port, app_name, service_name, value}}}
      end
    end)
  end

  defp expand_addons(_app_name, services, [], _app_middleware) do
    {:ok, services}
  end

  defp expand_addons(app_name, services, addon_names, app_middleware) do
    with :ok <- check_duplicate_addons(app_name, addon_names),
         :ok <- check_addon_collisions(app_name, services, addon_names),
         {:ok, addon_services} <-
           build_addon_services(app_name, addon_names, app_middleware) do
      updated_services = append_addon_dependencies(services, addon_names)
      {:ok, updated_services ++ addon_services}
    end
  end

  defp check_duplicate_addons(app_name, addon_names) do
    case addon_names -- Enum.uniq(addon_names) do
      [] -> :ok
      [name | _] -> {:error, {:duplicate_addon, app_name, name}}
    end
  end

  defp check_addon_collisions(app_name, services, addon_names) do
    service_names = MapSet.new(services, & &1.name)

    case Enum.find(addon_names, &MapSet.member?(service_names, &1)) do
      nil -> :ok
      name -> {:error, {:addon_name_collision, app_name, name}}
    end
  end

  defp build_addon_services(app_name, addon_names, app_middleware) do
    Enum.reduce_while(addon_names, {:ok, []}, fn name, {:ok, acc} ->
      case Addons.Registry.lookup(name) do
        {:ok, definition} ->
          service = build_addon_service(name, definition, app_middleware)
          {:cont, {:ok, acc ++ [service]}}

        {:error, :unknown} ->
          {:halt, {:error, {:unknown_addon, app_name, name}}}
      end
    end)
  end

  defp build_addon_service(name, definition, app_middleware) do
    port = if "port" in definition.middleware, do: :auto, else: nil

    %Service{
      name: name,
      command: definition.command,
      port: port,
      hostname: nil,
      middleware: app_middleware ++ definition.middleware,
      depends_on: []
    }
  end

  defp append_addon_dependencies(services, addon_names) do
    Enum.map(services, fn %Service{depends_on: depends_on} = service ->
      new_depends_on =
        Enum.reduce(addon_names, depends_on, fn name, acc ->
          if name in acc, do: acc, else: acc ++ [name]
        end)

      %Service{service | depends_on: new_depends_on}
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

  defp resolve_hostname(_app_name, value) when is_binary(value),
    do: "#{value}.test"

  defp resolve_port(nil), do: {:ok, nil}
  defp resolve_port(port) when is_integer(port), do: {:ok, port}
  defp resolve_port("auto"), do: {:ok, :auto}
  defp resolve_port(value), do: {:error, value}

  defp validate_middleware(applications) do
    Enum.reduce_while(applications, :ok, fn {_name, _root, services}, _acc ->
      case validate_services(services) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_services(services) do
    Enum.reduce_while(services, :ok, fn %Service{middleware: middleware},
                                        _acc ->
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

    Enum.reduce_while(services, :ok, fn %Service{
                                          name: name,
                                          depends_on: depends_on
                                        },
                                        _acc ->
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
