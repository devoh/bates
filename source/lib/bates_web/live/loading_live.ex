defmodule BatesWeb.LoadingLive do
  @moduledoc """
  Browser-facing loading page.

  Mounted by `BatesWeb.LoadingController` via `live_render/3` when the
  request looks like a browser (Accept includes `text/html`). The dead
  render kicks off `App.up/1` so the app starts even before the
  WebSocket connects (this was the bug in the previous LiveView-only
  implementation — non-browser clients never triggered startup).

  Non-browser clients hit the blocking controller path instead, which
  works without JS or WebSockets.
  """
  use BatesWeb, :live_view

  alias Bates.App
  alias BatesWeb.ServiceList

  @impl true
  def mount(
        _params,
        %{"app_name" => app_name, "service_name" => service_name},
        socket
      ) do
    if not connected?(socket) do
      safe_up(app_name)
    end

    services = ServiceList.fetch(app_name, service_name)

    if connected?(socket) do
      # Per-service broadcasts don't include the service name in the
      # payload, so we subscribe to every service topic and just
      # re-fetch services on every event below.
      for svc <- services do
        Phoenix.PubSub.subscribe(
          Bates.PubSub,
          "service:#{app_name}:#{svc.name}"
        )
      end

      Phoenix.PubSub.subscribe(Bates.PubSub, "app:#{app_name}")
    end

    hostname = service_hostname(services, service_name) || "#{app_name}.test"
    status = safe_status(app_name)

    socket =
      socket
      |> assign(:app_name, app_name)
      |> assign(:service_name, service_name)
      |> assign(:hostname, hostname)
      |> assign(:status, status)
      |> assign(:services, services)
      |> assign(:error_details, nil)

    if status == "up" do
      {:ok, replace_navigate(socket, "https://#{hostname}")}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:status, "up"}, socket) do
    case safe_status(socket.assigns.app_name) do
      "up" ->
        {:noreply,
         replace_navigate(socket, "https://#{socket.assigns.hostname}")}

      _ ->
        {:noreply, refresh_services(socket)}
    end
  end

  @impl true
  def handle_info({:status, "crashed", details}, socket) do
    {:noreply,
     socket
     |> assign(status: "crashed", error_details: details)
     |> refresh_services()}
  end

  @impl true
  def handle_info({:status, "crashed"}, socket) do
    {:noreply,
     socket
     |> assign(:status, "crashed")
     |> refresh_services()}
  end

  @impl true
  def handle_info({:status, status}, socket) do
    {:noreply,
     socket
     |> assign(:status, status)
     |> refresh_services()}
  end

  @impl true
  def handle_info({:exports_settled, _exports}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:addons_settled, _exports}, socket) do
    {:noreply, socket}
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

          <%= if @status == "crashed" do %>
            <h1 class="bates-loading__title bates-loading__title--error">{@app_name} crashed</h1>

            <%= if @error_details && @error_details != "" do %>
              <pre class="bates-loading__detail">{@error_details}</pre>
            <% end %>
          <% else %>
            <h1 class="bates-loading__title">Starting {@app_name}…</h1>

            <ServiceList.list services={@services} />
          <% end %>

        <footer class="bates-footer">
        </footer>
      </div>
    </main>
    """
  end

  # The loading page should not stay in browser history: once the app is
  # ready, hitting "back" from the app should go to wherever the user was
  # before, not back through the loading page. On the dead-render path
  # `live_render/3` emits a normal 302 (which browsers handle as a
  # history *replace*), so that branch is fine; on the connected path
  # LiveView's external redirect goes through `window.location = url`
  # which *pushes*. We use a custom client event + `location.replace`
  # to make the connected path also replace.
  defp replace_navigate(socket, url) do
    if connected?(socket) do
      push_event(socket, "bates:replace-navigate", %{url: url})
    else
      redirect(socket, external: url)
    end
  end

  defp refresh_services(socket) do
    %{app_name: app_name, service_name: service_name} = socket.assigns
    assign(socket, :services, ServiceList.fetch(app_name, service_name))
  end

  defp safe_up(app_name) do
    App.up(app_name)
  catch
    :exit, _ -> :ok
  end

  defp safe_status(app_name) do
    App.status(app_name)
  catch
    :exit, _ -> "unknown"
  end

  defp service_hostname(services, service_name) do
    Enum.find_value(services, fn service ->
      if service.name == service_name, do: service.hostname
    end)
  end
end
