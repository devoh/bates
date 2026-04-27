defmodule BatesWeb.DashboardLive do
  use BatesWeb, :live_view

  alias Bates.App
  alias Bates.ProcessSupervisor

  @impl true
  def mount(_params, _session, socket) do
    apps = build_app_list()

    if connected?(socket) do
      for app <- apps do
        Phoenix.PubSub.subscribe(Bates.PubSub, "app:#{app.name}")
      end
    end

    {:ok, assign(socket, apps: apps)}
  end

  @impl true
  def handle_info({:status, _status}, socket) do
    {:noreply, assign(socket, apps: build_app_list())}
  end

  @impl true
  def handle_info({:status, _status, _details}, socket) do
    {:noreply, assign(socket, apps: build_app_list())}
  end

  @impl true
  def handle_event("start", %{"name" => name}, socket) do
    App.up(name)
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop", %{"name" => name}, socket) do
    App.down(name)
    {:noreply, socket}
  end

  @impl true
  def handle_event("restart", %{"name" => name}, socket) do
    App.down(name)
    App.up(name)
    {:noreply, socket}
  end

  defp build_app_list do
    for name <- ProcessSupervisor.app_names() |> Enum.sort() do
      status = App.status(name)
      services = App.services(name)

      # For single-service apps, pull hostname and port from the sole service
      {hostname, port} =
        case services do
          [single] -> {single.hostname, single.port}
          _ -> {nil, nil}
        end

      %{
        name: name,
        hostname: hostname || "#{name}.test",
        status: status,
        port: port,
        services: services,
        multi_service: length(services) > 1
      }
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: system-ui, sans-serif; max-width: 800px; margin: 80px auto; padding: 0 20px;">
      <h1 style="font-size: 24px; font-weight: 600; margin-bottom: 32px;">Bates</h1>

      <%= if @apps == [] do %>
        <p style="color: #6b7280;">No applications configured.</p>
      <% else %>
        <table style="width: 100%; border-collapse: collapse;">
          <thead>
            <tr style="border-bottom: 2px solid #e5e7eb; text-align: left;">
              <th style="padding: 8px 12px; font-weight: 600; font-size: 14px;">Name</th>
              <th style="padding: 8px 12px; font-weight: 600; font-size: 14px;">Hostname</th>
              <th style="padding: 8px 12px; font-weight: 600; font-size: 14px;">Status</th>
              <th style="padding: 8px 12px; font-weight: 600; font-size: 14px;">Port</th>
              <th style="padding: 8px 12px; font-weight: 600; font-size: 14px;"></th>
            </tr>
          </thead>
          <tbody>
            <%= for app <- @apps do %>
              <tr style="border-bottom: 1px solid #e5e7eb;">
                <td style="padding: 10px 12px; font-size: 14px;"><%= app.name %></td>
                <td style="padding: 10px 12px; font-size: 14px;">
                  <a
                    href={"https://#{app.hostname}"}
                    style="color: #3b82f6; text-decoration: none;"
                  >
                    <%= app.hostname %>
                  </a>
                </td>
                <td style="padding: 10px 12px; font-size: 14px;">
                  <span style={"display: inline-block; padding: 2px 8px; border-radius: 9999px; font-size: 12px; font-weight: 500; #{status_style(app.status)}"}>
                    <%= app.status %>
                  </span>
                </td>
                <td style="padding: 10px 12px; font-size: 14px; color: #6b7280;">
                  <%= app.port %>
                </td>
                <td style="padding: 10px 12px; font-size: 14px;">
                  <div style="display: flex; gap: 8px;">
                    <%= if app.status in ["down", "crashed", "partial"] do %>
                      <button
                        phx-click="start"
                        phx-value-name={app.name}
                        style="padding: 4px 12px; border: 1px solid #d1d5db; border-radius: 6px; background: white; cursor: pointer; font-size: 13px;"
                      >
                        Start
                      </button>
                    <% end %>
                    <%= if app.status in ["starting", "up", "partial"] do %>
                      <button
                        phx-click="stop"
                        phx-value-name={app.name}
                        style="padding: 4px 12px; border: 1px solid #d1d5db; border-radius: 6px; background: white; cursor: pointer; font-size: 13px;"
                      >
                        Stop
                      </button>
                    <% end %>
                    <%= if app.status in ["up", "partial"] do %>
                      <button
                        phx-click="restart"
                        phx-value-name={app.name}
                        style="padding: 4px 12px; border: 1px solid #d1d5db; border-radius: 6px; background: white; cursor: pointer; font-size: 13px;"
                      >
                        Restart
                      </button>
                    <% end %>
                  </div>
                </td>
              </tr>
              <%= if app.multi_service do %>
                <%= for service <- app.services do %>
                  <tr style="border-bottom: 1px solid #f3f4f6; background: #fafafa;">
                    <td style="padding: 6px 12px 6px 28px; font-size: 13px; color: #6b7280;">
                      <%= service.name %>
                    </td>
                    <td style="padding: 6px 12px; font-size: 13px;">
                      <%= if service.hostname do %>
                        <a
                          href={"https://#{service.hostname}"}
                          style="color: #3b82f6; text-decoration: none;"
                        >
                          <%= service.hostname %>
                        </a>
                      <% end %>
                    </td>
                    <td style="padding: 6px 12px; font-size: 13px;">
                      <span style={"display: inline-block; padding: 2px 8px; border-radius: 9999px; font-size: 11px; font-weight: 500; #{status_style(service.status)}"}>
                        <%= service.status %>
                      </span>
                    </td>
                    <td style="padding: 6px 12px; font-size: 13px; color: #9ca3af;">
                      <%= service.port %>
                    </td>
                    <td></td>
                  </tr>
                <% end %>
              <% end %>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp status_style("up"), do: "background: #dcfce7; color: #166534;"
  defp status_style("starting"), do: "background: #dbeafe; color: #1e40af;"
  defp status_style("crashed"), do: "background: #fee2e2; color: #991b1b;"
  defp status_style("partial"), do: "background: #fef3c7; color: #92400e;"
  defp status_style("down"), do: "background: #f3f4f6; color: #374151;"
  defp status_style(_), do: "background: #f3f4f6; color: #374151;"
end
