defmodule BatesWeb.PausedLive do
  @moduledoc """
  Browser-facing paused page.

  Rendered by `BatesWeb.LoadingController` when the requested app is
  paused (`Bates.App.paused?/1` returns `true`). The page shows the
  list of services in the app and a Resume button that re-issues the
  request with `?resume=true`. That falls through to the normal
  loading flow, whose `App.up/1` call clears the paused flag.
  """
  use BatesWeb, :live_view

  alias Bates.App

  @impl true
  def mount(
        _params,
        %{"app_name" => app_name, "service_name" => service_name},
        socket
      ) do
    services = safe_services(app_name)

    socket =
      socket
      |> assign(:app_name, app_name)
      |> assign(:service_name, service_name)
      |> assign(:services, services)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="bates-loading">
      <div class="bates-loading__inner">
        <header class="bates-topbar">
          <div class="bates-wordmark">
            <span class="bates-wordmark__name">Bates</span>
            <span class="bates-wordmark__tag">at your service</span>
          </div>
        </header>

        <h1 class="bates-loading__title">{@app_name} is paused</h1>

        <ul class="bates-loading__chain">
          <li :for={svc <- @services} class="bates-loading__row">
            <span
              class={"bates-lamp bates-lamp--#{lamp_state(svc.status)}"}
              aria-hidden="true"
            >
            </span>
            <span class="bates-loading__service">{svc.name}</span>
          </li>
        </ul>

        <p>
          <a href="?resume=true" class="bates-btn bates-btn--ghost">Resume</a>
        </p>

        <footer class="bates-footer"></footer>
      </div>
    </main>
    """
  end

  defp lamp_state("up"), do: "running"
  defp lamp_state("down"), do: "stopped"
  defp lamp_state("starting"), do: "starting"
  defp lamp_state("crashed"), do: "error"
  defp lamp_state(_), do: "stopped"

  defp safe_services(app_name) do
    App.services(app_name)
  catch
    :exit, _ -> []
  end
end
