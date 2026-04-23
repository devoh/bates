defmodule ConjureWeb.ProcessController do
  use ConjureWeb, :controller

  alias Conjure.{Process, ProcessSupervisor}

  def status(conn, _params) do
    processes =
      for name <- ProcessSupervisor.process_names() do
        {:ok, port} = Process.port(name)
        status = Process.status(name)

        %{
          name: name,
          hostname: "#{name}.test",
          status: status,
          port: port
        }
      end

    json(conn, %{processes: processes})
  end

  def start(conn, %{"name" => name}) do
    case Process.up(name) do
      :ok ->
        json(conn, %{name: name, status: "up"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{name: name, error: inspect(reason)})
    end
  end

  def stop(conn, %{"name" => name}) do
    case Process.down(name) do
      :ok ->
        json(conn, %{name: name, status: "down"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{name: name, error: inspect(reason)})
    end
  end
end
