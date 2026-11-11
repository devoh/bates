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

  alias BatesWeb.ServiceList

  @impl true
  def mount(
        _params,
        %{"app_name" => app_name, "service_name" => service_name},
        socket
      ) do
    socket =
      socket
      |> assign(:app_name, app_name)
      |> assign(:service_name, service_name)
      |> assign(:services, ServiceList.fetch(app_name, service_name))

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

        <ServiceList.list services={@services} />

        <p>
          <a href="?resume=true" class="bates-btn bates-btn--ghost">Resume</a>
        </p>

        <footer class="bates-footer"></footer>
      </div>
    </main>
    """
  end
end
