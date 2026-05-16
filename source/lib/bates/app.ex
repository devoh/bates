defmodule Bates.App do
  use GenServer, restart: :transient
  require Logger

  alias Bates.{Middleware, ProcessInvocation, Service}

  @timeout 60_000
  @max_log_lines 1_000
  @poll_interval Application.compile_env(:bates, :poll_interval, 200)
  @readiness_timeout Application.compile_env(
                       :bates,
                       :readiness_timeout,
                       60_000
                     )

  # Public API

  def start_link({name, _root, _services} = config) do
    GenServer.start_link(__MODULE__, config, name: via_tuple(name))
  end

  def child_spec({name, _root, _services} = config) do
    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [config]},
      restart: :transient
    }
  end

  def up(name) do
    GenServer.call(via_tuple(name), :up, @timeout)
  end

  def down(name) do
    GenServer.call(via_tuple(name), :down, @timeout)
  end

  def status(name) do
    GenServer.call(via_tuple(name), :status)
  end

  def snapshot(name) do
    GenServer.call(via_tuple(name), :snapshot)
  end

  def service_status(name, service_name) do
    GenServer.call(via_tuple(name), {:service_status, service_name})
  end

  def services(name) do
    GenServer.call(via_tuple(name), :services)
  end

  def logs(name) do
    GenServer.call(via_tuple(name), :logs)
  end

  # Callbacks

  @impl GenServer
  def init({name, root, services}) do
    Process.flag(:trap_exit, true)

    service_states =
      Map.new(services, fn %Service{} = service ->
        {service.name,
         %{
           config: service,
           assigned_port: nil,
           pid: nil,
           ready: false,
           started_at: nil,
           exit_status: nil,
           exports: %{},
           log_buffer: :queue.new(),
           log_count: 0
         }}
      end)

    {:ok,
     %{
       name: name,
       root: root,
       services: service_states,
       pids: %{},
       exports_broadcast: false
     }}
  end

  @impl GenServer
  def handle_call(:up, _from, state) do
    new_state = state |> start_eligible() |> maybe_broadcast_exports_settled()
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  @impl GenServer
  def handle_call(:down, _from, state) do
    new_state =
      state
      |> reverse_topological_order()
      |> Enum.reduce(state, fn service_name, acc ->
        service_state = Map.fetch!(acc.services, service_name)

        if service_state.pid != nil do
          stop_service(acc, service_name, service_state)
        else
          acc
        end
      end)

    new_state = %{new_state | exports_broadcast: false}
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, derive_status(state), state}
  end

  @impl GenServer
  def handle_call({:service_status, service_name}, _from, state) do
    case Map.get(state.services, service_name) do
      nil -> {:reply, "unknown", state}
      service_state -> {:reply, service_status_name(service_state), state}
    end
  end

  @impl GenServer
  def handle_call(:services, _from, state) do
    service_list =
      Enum.map(state.services, fn {_name, svc} ->
        %{
          name: svc.config.name,
          hostname: svc.config.hostname,
          status: service_status_name(svc),
          port: svc.assigned_port,
          depends_on: svc.config.depends_on
        }
      end)

    {:reply, service_list, state}
  end

  @impl GenServer
  def handle_call(:logs, _from, state) do
    logs =
      Enum.map(state.services, fn {_name, svc} ->
        %{name: svc.config.name, lines: :queue.to_list(svc.log_buffer)}
      end)

    {:reply, logs, state}
  end

  @impl GenServer
  def handle_info({:check_ready, service_name}, state) do
    case Map.get(state.services, service_name) do
      %{pid: pid, ready: false, assigned_port: port} = svc
      when not is_nil(pid) ->
        case :gen_tcp.connect(~c"127.0.0.1", port, [], 100) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            new_svc = %{svc | ready: true}
            new_state = put_in(state, [:services, service_name], new_svc)
            broadcast_service(state.name, service_name, {:status, "up"})
            broadcast_app(state.name, {:status, derive_status(new_state)})

            new_state =
              new_state
              |> start_eligible()
              |> maybe_broadcast_exports_settled()

            {:noreply, new_state}

          {:error, _} ->
            elapsed = System.monotonic_time(:millisecond) - svc.started_at

            if elapsed >= @readiness_timeout do
              :exec.stop(pid)
              new_pids = Map.delete(state.pids, pid)
              message = "Timed out waiting for port #{port}"

              new_svc = %{
                svc
                | pid: nil,
                  ready: false,
                  started_at: nil,
                  exit_status: :timeout,
                  exports: %{}
              }

              new_state = %{state | pids: new_pids}
              new_state = put_in(new_state, [:services, service_name], new_svc)

              broadcast_service(
                state.name,
                service_name,
                {:status, "crashed", message}
              )

              broadcast_app(state.name, {:status, derive_status(new_state)})
              {:noreply, maybe_broadcast_exports_settled(new_state)}
            else
              Process.send_after(
                self(),
                {:check_ready, service_name},
                @poll_interval
              )

              {:noreply, state}
            end
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({stream, os_pid, data}, state)
      when stream in [:stdout, :stderr] do
    case Map.get(state.pids, os_pid) do
      nil ->
        {:noreply, state}

      service_name ->
        message = String.trim(data)
        log(state.name, service_name, message)
        svc = Map.fetch!(state.services, service_name)
        new_svc = buffer_log(svc, message)
        new_state = put_in(state, [:services, service_name], new_svc)
        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({:EXIT, exit_pid, reason}, state) do
    case Map.get(state.pids, exit_pid) do
      nil ->
        {:noreply, state}

      service_name ->
        svc = Map.fetch!(state.services, service_name)
        new_pids = Map.delete(state.pids, exit_pid)
        new_svc = %{svc | pid: nil, exports: %{}}

        {new_svc, broadcast_msg} =
          if svc.exit_status == :timeout do
            # Already handled in check_ready timeout
            {new_svc, nil}
          else
            exit_status = extract_exit_status(reason)

            if exit_status == :normal do
              {%{new_svc | exit_status: :normal}, {:status, "down"}}
            else
              new_svc = %{new_svc | exit_status: exit_status}
              log_output = drain_log_buffer(new_svc)
              {new_svc, {:status, "crashed", log_output}}
            end
          end

        new_state = %{state | pids: new_pids}
        new_state = put_in(new_state, [:services, service_name], new_svc)

        if broadcast_msg do
          broadcast_service(state.name, service_name, broadcast_msg)
          broadcast_app(state.name, {:status, derive_status(new_state)})
        end

        {:noreply, maybe_broadcast_exports_settled(new_state)}
    end
  end

  # Helpers

  defp reverse_topological_order(state) do
    graph = build_dependency_graph(state.services)

    try do
      :digraph_utils.topsort(graph)
    after
      :digraph.delete(graph)
    end
  end

  defp build_dependency_graph(services) do
    graph = :digraph.new()

    Enum.each(services, fn {name, _service} ->
      :digraph.add_vertex(graph, name)
    end)

    Enum.each(services, fn {name, %{config: %Service{depends_on: depends_on}}} ->
      Enum.each(depends_on, fn dependency_name ->
        :digraph.add_edge(graph, name, dependency_name)
      end)
    end)

    graph
  end

  defp start_eligible(state) do
    Enum.reduce(state.services, state, fn {service_name, service_state}, acc ->
      if eligible_to_start?(service_state, acc.services) do
        start_service(acc, service_name, service_state)
      else
        acc
      end
    end)
  end

  defp eligible_to_start?(%{pid: pid}, _services) when not is_nil(pid),
    do: false

  defp eligible_to_start?(
         %{config: %Service{depends_on: depends_on}},
         services
       ) do
    Enum.all?(depends_on, fn dependency_name ->
      case Map.get(services, dependency_name) do
        nil -> false
        dependency_state -> service_status_name(dependency_state) == "up"
      end
    end)
  end

  defp start_service(state, service_name, service_state) do
    config = service_state.config

    assigned_port = assign_port(config)
    service_state = %{service_state | assigned_port: assigned_port}

    update_caddy_route(config.hostname, assigned_port)

    invocation = build_invocation(config, assigned_port, state)
    command = invocation |> ProcessInvocation.compile() |> to_charlist()
    root = state.root |> Path.expand() |> to_charlist()
    env = build_env(invocation.environment)
    opts = [:stdout, :stderr, cd: root, env: env]

    case :exec.run_link(command, opts) do
      {:ok, pid, os_pid} ->
        new_svc = %{
          service_state
          | pid: pid,
            ready: false,
            exit_status: nil,
            exports: invocation.exports
        }

        new_pids = Map.put(state.pids, pid, service_name)
        # Also map the os_pid for stdout/stderr routing
        new_pids = Map.put(new_pids, os_pid, service_name)

        broadcast_service(state.name, service_name, {:status, "starting"})

        if assigned_port == nil do
          new_svc = %{new_svc | ready: true}
          new_state = %{state | pids: new_pids}
          new_state = put_in(new_state, [:services, service_name], new_svc)
          broadcast_service(state.name, service_name, {:status, "up"})
          broadcast_app(state.name, {:status, derive_status(new_state)})
          maybe_broadcast_exports_settled(new_state)
        else
          Process.send_after(
            self(),
            {:check_ready, service_name},
            @poll_interval
          )

          started_at = System.monotonic_time(:millisecond)
          new_svc = %{new_svc | started_at: started_at}
          new_state = %{state | pids: new_pids}
          new_state = put_in(new_state, [:services, service_name], new_svc)
          broadcast_app(state.name, {:status, derive_status(new_state)})
          maybe_broadcast_exports_settled(new_state)
        end

      {:error, reason} ->
        Logger.error(
          "Failed to start service #{service_name}: #{inspect(reason)}"
        )

        state
    end
  end

  defp stop_service(state, service_name, service_state) do
    pid = service_state.pid
    :exec.kill(pid, :sigkill)

    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> :ok
    end

    revert_caddy_route(service_state.config.hostname)

    new_svc = %{
      service_state
      | pid: nil,
        ready: false,
        started_at: nil,
        exit_status: nil,
        assigned_port: nil,
        exports: %{}
    }

    new_pids = Map.delete(state.pids, pid)
    new_state = %{state | pids: new_pids}
    new_state = put_in(new_state, [:services, service_name], new_svc)

    broadcast_service(state.name, service_name, {:status, "down"})
    broadcast_app(state.name, {:status, derive_status(new_state)})

    new_state
  end

  defp derive_status(state) do
    statuses =
      Enum.map(state.services, fn {_name, svc} -> service_status_name(svc) end)

    cond do
      Enum.all?(statuses, &(&1 == "up")) -> "up"
      Enum.all?(statuses, &(&1 == "down")) -> "down"
      Enum.any?(statuses, &(&1 == "crashed")) -> "crashed"
      Enum.all?(statuses, &(&1 in ["starting", "up"])) -> "starting"
      true -> "partial"
    end
  end

  defp maybe_broadcast_exports_settled(state) do
    if not state.exports_broadcast and all_services_settled?(state) do
      exports = merge_exports(state)
      broadcast_app(state.name, {:exports_settled, exports})
      %{state | exports_broadcast: true}
    else
      state
    end
  end

  defp all_services_settled?(state) do
    Enum.all?(state.services, fn {_name, svc} ->
      svc.pid != nil or svc.exit_status != nil
    end)
  end

  defp merge_exports(state) do
    Enum.reduce(state.services, %{}, fn {_name, svc}, acc ->
      Map.merge(acc, svc.exports)
    end)
  end

  defp build_snapshot(state) do
    status = derive_status(state)
    exports = merge_exports(state)
    reason = crash_reason(state, status)
    %{status: status, exports: exports, reason: reason}
  end

  defp crash_reason(state, "crashed") do
    state.services
    |> Enum.sort_by(fn {name, _svc} -> name end)
    |> Enum.find_value(fn {name, svc} ->
      case svc.exit_status do
        nil -> nil
        :normal -> nil
        status -> "service #{name} failed: #{inspect(status)}"
      end
    end)
  end

  defp crash_reason(_state, _), do: nil

  defp service_status_name(%{pid: pid, ready: true}) when not is_nil(pid),
    do: "up"

  defp service_status_name(%{pid: pid, ready: false}) when not is_nil(pid),
    do: "starting"

  defp service_status_name(%{exit_status: exit}) when exit in [:normal, nil],
    do: "down"

  defp service_status_name(_), do: "crashed"

  defp broadcast_service(app_name, service_name, message) do
    Phoenix.PubSub.broadcast(
      Bates.PubSub,
      "service:#{app_name}:#{service_name}",
      message
    )
  end

  defp broadcast_app(app_name, message) do
    Phoenix.PubSub.broadcast(Bates.PubSub, "app:#{app_name}", message)
  end

  defp buffer_log(%{log_buffer: buffer, log_count: count} = svc, message) do
    if count >= @max_log_lines do
      {_, trimmed} = :queue.out(buffer)
      %{svc | log_buffer: :queue.in(message, trimmed)}
    else
      %{svc | log_buffer: :queue.in(message, buffer), log_count: count + 1}
    end
  end

  defp drain_log_buffer(%{log_buffer: buffer}) do
    :queue.to_list(buffer) |> Enum.join("\n")
  end

  defp build_invocation(%Service{} = config, assigned_port, state) do
    validate_routable_middleware!(config)

    modules = Enum.map(config.middleware, &Middleware.Registry.lookup!/1)
    seed = seed_environment(config, state)
    initial = %ProcessInvocation{command: config.command, environment: seed}

    context = %{
      assigned_port: assigned_port,
      service: config,
      app_name: state.name,
      root: state.root
    }

    Middleware.apply_pipeline(initial, modules, context)
  end

  defp seed_environment(%Service{name: name}, state) do
    graph = build_dependency_graph(state.services)

    try do
      closure = MapSet.new(:digraph_utils.reachable([name], graph) -- [name])

      graph
      |> :digraph_utils.topsort()
      |> Enum.filter(&MapSet.member?(closure, &1))
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn dependency_name, acc ->
        dependency_state = Map.fetch!(state.services, dependency_name)
        Map.merge(acc, dependency_state.exports)
      end)
    after
      :digraph.delete(graph)
    end
  end

  defp validate_routable_middleware!(%Service{hostname: nil}), do: :ok

  defp validate_routable_middleware!(%Service{
         name: name,
         middleware: middleware
       }) do
    if "port" in middleware do
      :ok
    else
      raise "Service #{inspect(name)} has a hostname but no \"port\" middleware. " <>
              "Add \"port\" to its middleware list."
    end
  end

  defp build_env(environment) do
    user_env =
      Enum.map(environment, fn {key, value} ->
        {to_charlist(key), to_charlist(value)}
      end)

    scrub_path() ++ user_env
  end

  # When `batesd` runs as a Mix release, the launcher prepends
  # `<release_root>/erts-*/bin` and `<release_root>/bin` to PATH so the daemon
  # finds its own `erl`. Children inherit that PATH, so a user service
  # running `elixir`/`mix` resolves `erl` to bates's release `erl` (which
  # computes `ROOTDIR` from its own location) and then fails to find
  # `<release_root>/bin/start.boot`. Strip those entries before handing PATH
  # to the child.
  defp scrub_path do
    with release_root when is_binary(release_root) <-
           System.get_env("RELEASE_ROOT"),
         path when is_binary(path) <- System.get_env("PATH") do
      scrubbed =
        path
        |> String.split(":", trim: true)
        |> Enum.reject(&path_inside_release?(&1, release_root))
        |> Enum.join(":")

      [{~c"PATH", to_charlist(scrubbed)}]
    else
      _ -> []
    end
  end

  defp path_inside_release?(entry, release_root) do
    entry == Path.join(release_root, "bin") or
      String.starts_with?(entry, Path.join(release_root, "erts-"))
  end

  defp log(app_name, service_name, message) do
    prefix =
      if app_name == service_name do
        "[#{app_name}]"
      else
        "[#{app_name}:#{service_name}]"
      end

    Logger.info("#{prefix} #{message}")
  end

  defp assign_port(%Service{port: port}) when is_integer(port), do: port

  defp assign_port(%Service{port: :auto}), do: Bates.PortNumber.next()

  defp assign_port(%Service{hostname: hostname}) when not is_nil(hostname),
    do: Bates.PortNumber.next()

  defp assign_port(_service), do: nil

  defp update_caddy_route(nil, _port), do: :ok
  defp update_caddy_route(_hostname, nil), do: :ok

  defp update_caddy_route(hostname, port) do
    case Bates.Caddy.update_route(hostname, port) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to update Caddy route for #{hostname}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp revert_caddy_route(nil), do: :ok

  defp revert_caddy_route(hostname) do
    case Bates.Caddy.revert_route(hostname) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to revert Caddy route for #{hostname}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp extract_exit_status(:normal), do: :normal
  defp extract_exit_status({:exit_status, _status}), do: :crashed
  defp extract_exit_status(_), do: :crashed

  defp via_tuple(name) when is_binary(name) do
    {:via, Registry, {Bates.ProcessRegistry, name}}
  end
end
