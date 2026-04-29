defmodule BatesWeb.LoadingController do
  use BatesWeb, :controller

  alias Bates.App

  @timeout Application.compile_env(:bates, :readiness_timeout, 60_000)

  def show(conn, %{"app_name" => app_name, "service_name" => service_name}) do
    Phoenix.PubSub.subscribe(Bates.PubSub, "service:#{app_name}:#{service_name}")
    Phoenix.PubSub.subscribe(Bates.PubSub, "app:#{app_name}")

    try do
      App.up(app_name)
    catch
      :exit, _ -> :ok
    end

    hostname = find_hostname(app_name, service_name)

    case await_ready(app_name) do
      :up ->
        redirect(conn, external: "https://#{hostname}")

      {:crashed, details} ->
        conn
        |> put_status(502)
        |> text("#{app_name} crashed\n\n#{details}")

      :timeout ->
        conn
        |> put_status(504)
        |> text("#{app_name} did not start within #{div(@timeout, 1_000)}s")
    end
  end

  defp await_ready(app_name) do
    status =
      try do
        App.status(app_name)
      catch
        :exit, _ -> "unknown"
      end

    case status do
      "up" -> :up
      "crashed" -> {:crashed, ""}
      _ -> await_status(@timeout)
    end
  end

  defp await_status(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    receive_until(deadline)
  end

  defp receive_until(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      receive do
        {:status, "up"} -> :up
        {:status, "crashed", details} -> {:crashed, details}
        {:status, "crashed"} -> {:crashed, ""}
        {:status, _} -> receive_until(deadline)
      after
        remaining -> :timeout
      end
    end
  end

  defp find_hostname(app_name, service_name) do
    try do
      App.services(app_name)
      |> Enum.find_value(fn service ->
        if service.name == service_name, do: service.hostname
      end)
    catch
      :exit, _ -> nil
    end
  end
end
