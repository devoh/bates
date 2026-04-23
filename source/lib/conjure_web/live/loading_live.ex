defmodule ConjureWeb.LoadingLive do
  use ConjureWeb, :live_view

  alias Conjure.Process

  @impl true
  def mount(%{"app_name" => app_name}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Conjure.PubSub, "process:#{app_name}")
      Process.up(app_name)
    end

    status =
      try do
        Process.status(app_name)
      catch
        :exit, _ -> "unknown"
      end

    {:ok,
     assign(socket,
       app_name: app_name,
       status: status,
       error: nil
     )}
  end

  @impl true
  def handle_info({:status, "up"}, socket) do
    app_name = socket.assigns.app_name
    {:noreply, redirect(socket, external: "https://#{app_name}.test")}
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
end
