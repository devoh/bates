defmodule ConjureWeb.DashboardLive do
  use ConjureWeb, :live_view

  alias Conjure.Process, as: AppProcess
  alias Conjure.ProcessSupervisor

  @impl true
  def mount(_params, _session, socket) do
    processes = build_process_list()

    if connected?(socket) do
      for process <- processes do
        Phoenix.PubSub.subscribe(Conjure.PubSub, "process:#{process.name}")
      end
    end

    {:ok, assign(socket, processes: processes)}
  end

  @impl true
  def handle_info({:status, _status}, socket) do
    {:noreply, assign(socket, processes: build_process_list())}
  end

  @impl true
  def handle_info({:status, _status, _details}, socket) do
    {:noreply, assign(socket, processes: build_process_list())}
  end

  @impl true
  def handle_event("start", %{"name" => name}, socket) do
    AppProcess.up(name)
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop", %{"name" => name}, socket) do
    AppProcess.down(name)
    {:noreply, socket}
  end

  @impl true
  def handle_event("restart", %{"name" => name}, socket) do
    AppProcess.down(name)
    AppProcess.up(name)
    {:noreply, socket}
  end

  defp build_process_list do
    for name <- ProcessSupervisor.process_names() |> Enum.sort() do
      status =
        try do
          AppProcess.status(name)
        catch
          :exit, _ -> "unknown"
        end

      {:ok, port} =
        try do
          AppProcess.port(name)
        catch
          :exit, _ -> {:ok, nil}
        end

      %{name: name, hostname: "#{name}.test", status: status, port: port}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: system-ui, sans-serif; max-width: 800px; margin: 80px auto; padding: 0 20px;">
      <h1 style="font-size: 24px; font-weight: 600; margin-bottom: 32px;">Conjure</h1>

      <%= if @processes == [] do %>
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
            <tr :for={process <- @processes} style="border-bottom: 1px solid #e5e7eb;">
              <td style="padding: 10px 12px; font-size: 14px;"><%= process.name %></td>
              <td style="padding: 10px 12px; font-size: 14px;">
                <a
                  href={"https://#{process.hostname}"}
                  style="color: #3b82f6; text-decoration: none;"
                >
                  <%= process.hostname %>
                </a>
              </td>
              <td style="padding: 10px 12px; font-size: 14px;">
                <span style={"display: inline-block; padding: 2px 8px; border-radius: 9999px; font-size: 12px; font-weight: 500; #{status_style(process.status)}"}>
                  <%= process.status %>
                </span>
              </td>
              <td style="padding: 10px 12px; font-size: 14px; color: #6b7280;">
                <%= process.port %>
              </td>
              <td style="padding: 10px 12px; font-size: 14px;">
                <div style="display: flex; gap: 8px;">
                  <%= if process.status in ["down", "crashed"] do %>
                    <button
                      phx-click="start"
                      phx-value-name={process.name}
                      style="padding: 4px 12px; border: 1px solid #d1d5db; border-radius: 6px; background: white; cursor: pointer; font-size: 13px;"
                    >
                      Start
                    </button>
                  <% end %>
                  <%= if process.status in ["starting", "up"] do %>
                    <button
                      phx-click="stop"
                      phx-value-name={process.name}
                      style="padding: 4px 12px; border: 1px solid #d1d5db; border-radius: 6px; background: white; cursor: pointer; font-size: 13px;"
                    >
                      Stop
                    </button>
                  <% end %>
                  <%= if process.status == "up" do %>
                    <button
                      phx-click="restart"
                      phx-value-name={process.name}
                      style="padding: 4px 12px; border: 1px solid #d1d5db; border-radius: 6px; background: white; cursor: pointer; font-size: 13px;"
                    >
                      Restart
                    </button>
                  <% end %>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp status_style("up"), do: "background: #dcfce7; color: #166534;"
  defp status_style("starting"), do: "background: #dbeafe; color: #1e40af;"
  defp status_style("crashed"), do: "background: #fee2e2; color: #991b1b;"
  defp status_style("down"), do: "background: #f3f4f6; color: #374151;"
  defp status_style(_), do: "background: #f3f4f6; color: #374151;"
end
