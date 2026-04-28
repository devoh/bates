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
              %{name: svc.name, hostname: svc.hostname, status: svc.status, port: svc.port}
            end)
        }
      end

    json(conn, %{processes: processes})
  end

  def start(conn, %{"name" => name}) do
    case App.up(name) do
      :ok ->
        json(conn, %{name: name, status: "up"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{name: name, error: inspect(reason)})
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
end
