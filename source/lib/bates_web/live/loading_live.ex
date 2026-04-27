defmodule BatesWeb.LoadingLive do
  use BatesWeb, :live_view

  alias Bates.App

  @impl true
  def mount(%{"app_name" => app_name} = params, _session, socket) do
    hostname = params["hostname"]

    if connected?(socket) do
      if hostname do
        # Find which service this hostname belongs to and subscribe to it
        service = find_service_by_hostname(app_name, hostname)

        if service do
          Phoenix.PubSub.subscribe(Bates.PubSub, "service:#{app_name}:#{service.name}")
        end
      else
        Phoenix.PubSub.subscribe(Bates.PubSub, "app:#{app_name}")
      end

      try do
        App.up(app_name)
      catch
        :exit, _ -> :ok
      end
    end

    status =
      try do
        App.status(app_name)
      catch
        :exit, _ -> "unknown"
      end

    redirect_hostname = hostname || "#{app_name}.test"
    socket = assign(socket, app_name: app_name, status: status, error: nil, redirect_hostname: redirect_hostname)

    if connected?(socket) and status == "up" do
      {:ok, redirect(socket, external: "https://#{redirect_hostname}")}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:status, "up"}, socket) do
    {:noreply, redirect(socket, external: "https://#{socket.assigns.redirect_hostname}")}
  end

  @impl true
  def handle_info({:status, "crashed", details}, socket) do
    {:noreply, assign(socket, status: "crashed", error: details)}
  end

  @impl true
  def handle_info({:status, status}, socket) do
    {:noreply, assign(socket, status: status)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: system-ui, sans-serif; max-width: 600px; margin: 80px auto; padding: 0 20px;">
      <h1 style="font-size: 24px; font-weight: 600;"><%= @app_name %></h1>

      <%= if @status == "crashed" do %>
        <p style="color: #dc2626;">Application crashed.</p>
        <%= if @error do %>
          <pre style="background: #1e1e1e; color: #d4d4d4; padding: 16px; border-radius: 8px; overflow-x: auto; font-size: 13px;"><%= @error %></pre>
        <% end %>
      <% else %>
        <p style="color: #6b7280;">Starting application&hellip;</p>
        <div style="width: 100%; height: 4px; background: #e5e7eb; border-radius: 2px; overflow: hidden;">
          <div style="width: 30%; height: 100%; background: #3b82f6; border-radius: 2px; animation: pulse 1.5s ease-in-out infinite;">
          </div>
        </div>
        <style>
          @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
          }
        </style>
      <% end %>
    </div>
    """
  end

  defp find_service_by_hostname(app_name, hostname) do
    try do
      App.services(app_name)
      |> Enum.find(&(&1.hostname == hostname))
    catch
      :exit, _ -> nil
    end
  end
end
