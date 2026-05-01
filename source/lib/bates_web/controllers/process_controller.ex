defmodule BatesWeb.ProcessController do
  use BatesWeb, :controller

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
        try do
          App.up(name)
        catch
          :exit, _ -> :ok
        end

        await_settled(conn, name, timeout())
    end
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
          json(conn, %{name: name, status: "up", exports: exports})

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

  defp timeout_response(conn, name) do
    conn
    |> put_status(504)
    |> json(%{
      name: name,
      status: "timeout",
      reason: "timed out waiting for exports"
    })
  end
end
