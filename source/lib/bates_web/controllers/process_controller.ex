defmodule BatesWeb.ProcessController do
  use BatesWeb, :controller

  require Logger

  alias Bates.{App, ProcessSupervisor}

  def status(conn, _params) do
    processes =
      for name <- ProcessSupervisor.app_names() do
        status = App.status(name)
        services = App.services(name)

        %{
          name: name,
          status: status,
          services:
            Enum.map(services, fn svc ->
              %{
                name: svc.name,
                hostname: svc.hostname,
                status: svc.status,
                port: svc.port
              }
            end)
        }
      end

    json(conn, %{processes: processes})
  end

  def start(conn, %{"name" => name}) do
    case ProcessSupervisor.app_pid(name) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{
          name: name,
          status: "unknown",
          reason: "unknown application: #{name}"
        })

      _pid ->
        # Subscribe before snapshotting so a broadcast that fires
        # between the snapshot read and the receive loop still lands
        # in this process's mailbox. Snapshot-then-subscribe would
        # drop a settling message that arrives in that gap.
        Phoenix.PubSub.subscribe(Bates.PubSub, "app:#{name}")
        await_start_response(conn, name)
    end
  end

  def env(conn, %{"name" => name}) do
    case ProcessSupervisor.app_pid(name) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{
          name: name,
          status: "unknown",
          reason: "unknown application: #{name}"
        })

      _pid ->
        Phoenix.PubSub.subscribe(Bates.PubSub, "app:#{name}")
        await_env_response(conn, name)
    end
  end

  def stop(conn, %{"name" => name}) do
    case App.down(name) do
      :ok ->
        json(conn, %{name: name, status: "down"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{name: name, error: inspect(reason)})
    end
  end

  def logs(conn, %{"name" => name}) do
    logs = App.logs(name)
    json(conn, %{name: name, services: logs})
  end

  def restart(conn, %{"name" => name}) do
    with :ok <- App.down(name),
         :ok <- App.up(name) do
      json(conn, %{name: name, status: "up"})
    else
      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{name: name, error: inspect(reason)})
    end
  end

  def start_service(conn, %{"app" => app, "service" => service}) do
    with {:ok, _pid} <- fetch_app(app),
         {:ok, svc} <- fetch_service(app, service) do
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:#{app}:#{service}")

      cond do
        App.service_status(app, service) == "up" ->
          respond_service_up(conn, app, service, svc)

        true ->
          dispatch_start_service(conn, app, service, svc)
      end
    else
      {:error, :unknown_app} ->
        conn
        |> put_status(404)
        |> json(%{
          app: app,
          service: service,
          status: "unknown",
          reason: "unknown application: #{app}"
        })

      {:error, :unknown_service} ->
        conn
        |> put_status(404)
        |> json(%{
          app: app,
          service: service,
          status: "unknown",
          reason: "unknown service: #{service}"
        })
    end
  end

  defp dispatch_start_service(conn, app, service, svc) do
    case start_app_service(app, service) do
      :ok ->
        await_service_settled(conn, app, service, svc, timeout())

      {:error, :unknown_service} ->
        conn
        |> put_status(404)
        |> json(%{
          app: app,
          service: service,
          status: "unknown",
          reason: "unknown service: #{service}"
        })

      {:error, reason} ->
        Logger.error(
          "App.up/2 exited for #{app}:#{service}: #{inspect(reason)}"
        )

        conn
        |> put_status(500)
        |> json(%{
          app: app,
          service: service,
          status: "error",
          reason: "internal error: #{inspect(reason)}"
        })
    end
  end

  def stop_service(conn, %{"app" => app, "service" => service}) do
    with {:ok, _pid} <- fetch_app(app),
         {:ok, _svc} <- fetch_service(app, service) do
      case stop_app_service(app, service) do
        {:ok, cascaded} ->
          json(conn, %{
            app: app,
            service: service,
            status: "down",
            cascaded: cascaded
          })

        {:error, :unknown_service} ->
          conn
          |> put_status(404)
          |> json(%{
            app: app,
            service: service,
            status: "unknown",
            reason: "unknown service: #{service}"
          })

        {:error, reason} ->
          conn
          |> put_status(422)
          |> json(%{
            app: app,
            service: service,
            error: inspect(reason)
          })
      end
    else
      {:error, :unknown_app} ->
        conn
        |> put_status(404)
        |> json(%{
          app: app,
          service: service,
          status: "unknown",
          reason: "unknown application: #{app}"
        })

      {:error, :unknown_service} ->
        conn
        |> put_status(404)
        |> json(%{
          app: app,
          service: service,
          status: "unknown",
          reason: "unknown service: #{service}"
        })
    end
  end

  defp fetch_app(app) do
    case ProcessSupervisor.app_pid(app) do
      nil -> {:error, :unknown_app}
      pid -> {:ok, pid}
    end
  end

  defp fetch_service(app, service) do
    case Enum.find(App.services(app), &(&1.name == service)) do
      nil -> {:error, :unknown_service}
      svc -> {:ok, svc}
    end
  end

  defp start_app_service(app, service) do
    App.up(app, service)
  catch
    :exit, reason -> {:error, reason}
  end

  defp stop_app_service(app, service) do
    App.down(app, service)
  catch
    :exit, reason -> {:error, reason}
  end

  defp await_service_settled(conn, app, service, svc, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_service_settled(conn, app, service, svc, deadline)
  end

  defp receive_service_settled(conn, app, service, svc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      service_timeout_response(conn, app, service)
    else
      receive do
        {:status, "up"} ->
          respond_service_up(conn, app, service, svc)

        {:status, "crashed", reason} ->
          conn
          |> put_status(422)
          |> json(%{
            app: app,
            service: service,
            status: "crashed",
            reason: reason
          })

        {:status, "crashed"} ->
          conn
          |> put_status(422)
          |> json(%{
            app: app,
            service: service,
            status: "crashed",
            reason: "service crashed"
          })

        _ ->
          receive_service_settled(conn, app, service, svc, deadline)
      after
        remaining -> service_timeout_response(conn, app, service)
      end
    end
  end

  defp respond_service_up(conn, app, service, svc) do
    case Enum.find(App.services(app), &(&1.name == service)) do
      nil ->
        json(conn, %{
          app: app,
          service: service,
          status: "up",
          port: svc.port,
          hostname: svc.hostname
        })

      latest ->
        json(conn, %{
          app: app,
          service: service,
          status: "up",
          port: latest.port,
          hostname: latest.hostname
        })
    end
  end

  defp service_timeout_response(conn, app, service) do
    conn
    |> put_status(504)
    |> json(%{
      app: app,
      service: service,
      status: "timeout",
      reason: "timed out waiting for #{service} to start"
    })
  end

  defp await_start_response(conn, name) do
    case App.snapshot(name) do
      %{status: "up", exports: exports} ->
        json(conn, %{name: name, status: "up", exports: exports})

      %{status: "crashed", reason: reason} ->
        conn
        |> put_status(422)
        |> json(%{
          name: name,
          status: "crashed",
          reason: reason || "application crashed"
        })

      _ ->
        case start_app(name) do
          :ok ->
            await_settled(conn, name, timeout())

          {:error, reason} ->
            Logger.error("App.up/1 exited for #{name}: #{inspect(reason)}")

            conn
            |> put_status(500)
            |> json(%{
              name: name,
              status: "error",
              reason: "internal error: #{inspect(reason)}"
            })
        end
    end
  end

  defp start_app(name) do
    App.up(name)
  catch
    :exit, reason -> {:error, reason}
  end

  defp timeout do
    Application.get_env(:bates, :readiness_timeout, 60_000)
  end

  defp await_settled(conn, name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_settled(conn, name, deadline)
  end

  defp receive_settled(conn, name, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      timeout_response(conn, name)
    else
      receive do
        {:exports_settled, exports} ->
          respond_settled(conn, name, exports)

        {:status, "crashed", reason} ->
          conn
          |> put_status(422)
          |> json(%{name: name, status: "crashed", reason: reason})

        {:status, "crashed"} ->
          conn
          |> put_status(422)
          |> json(%{
            name: name,
            status: "crashed",
            reason: "application crashed"
          })

        _ ->
          receive_settled(conn, name, deadline)
      after
        remaining -> timeout_response(conn, name)
      end
    end
  end

  defp respond_settled(conn, name, exports) do
    case App.snapshot(name) do
      %{status: "crashed", reason: reason} ->
        conn
        |> put_status(422)
        |> json(%{
          name: name,
          status: "crashed",
          reason: reason || "application crashed"
        })

      %{status: status} ->
        json(conn, %{name: name, status: status, exports: exports})
    end
  end

  defp timeout_response(conn, name) do
    conn
    |> put_status(504)
    |> json(%{
      name: name,
      status: "timeout",
      reason: "timed out waiting for exports"
    })
  end

  defp await_env_response(conn, name) do
    case App.addon_snapshot(name) do
      %{status: "up", exports: exports} ->
        json(conn, %{name: name, status: "up", exports: exports})

      %{status: "crashed", reason: reason} ->
        conn
        |> put_status(422)
        |> json(%{
          name: name,
          status: "crashed",
          reason: reason || "addon crashed"
        })

      _ ->
        case start_addons(name) do
          :ok ->
            await_addons_settled(conn, name, timeout())

          {:error, reason} ->
            Logger.error("App.up_addons/1 exited for #{name}: #{inspect(reason)}")

            conn
            |> put_status(500)
            |> json(%{
              name: name,
              status: "error",
              reason: "internal error: #{inspect(reason)}"
            })
        end
    end
  end

  defp start_addons(name) do
    App.up_addons(name)
  catch
    :exit, reason -> {:error, reason}
  end

  defp await_addons_settled(conn, name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_addons_settled(conn, name, deadline)
  end

  defp receive_addons_settled(conn, name, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      addons_timeout_response(conn, name)
    else
      receive do
        {:addons_settled, exports} ->
          respond_addons_settled(conn, name, exports)

        _ ->
          receive_addons_settled(conn, name, deadline)
      after
        remaining -> addons_timeout_response(conn, name)
      end
    end
  end

  defp respond_addons_settled(conn, name, exports) do
    case App.addon_snapshot(name) do
      %{status: "crashed", reason: reason} ->
        conn
        |> put_status(422)
        |> json(%{
          name: name,
          status: "crashed",
          reason: reason || "addon crashed"
        })

      %{status: status} ->
        json(conn, %{name: name, status: status, exports: exports})
    end
  end

  defp addons_timeout_response(conn, name) do
    conn
    |> put_status(504)
    |> json(%{
      name: name,
      status: "timeout",
      reason: "timed out waiting for addons"
    })
  end
end
