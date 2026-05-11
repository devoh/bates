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
  def handle_info({:exports_settled, _exports}, socket) do
    {:noreply, socket}
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

  defp lamp_state("up"), do: "running"
  defp lamp_state("down"), do: "stopped"
  defp lamp_state("starting"), do: "starting"
  defp lamp_state("partial"), do: "partial"
  defp lamp_state("crashed"), do: "error"
  defp lamp_state(_), do: "stopped"

  defp service_error_count(services) do
    Enum.count(services, fn s -> lamp_state(s.status) == "error" end)
  end

  defp summary_stats(apps) do
    total = length(apps)
    running = Enum.count(apps, &(&1.status == "up"))
    stopped = Enum.count(apps, &(&1.status == "down"))
    failed = Enum.count(apps, &(&1.status == "crashed"))

    [
      %{label: "Apps", value: total, lamp: "neutral", tone: "neutral"},
      %{label: "Running", value: running, lamp: "running", tone: "running"},
      %{label: "Stopped", value: stopped, lamp: "stopped", tone: "stopped"},
      %{
        label: "Failed",
        value: failed,
        lamp: if(failed > 0, do: "error", else: "stopped"),
        tone: if(failed > 0, do: "error", else: "stopped")
      }
    ]
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :stats, summary_stats(assigns.apps))

    ~H"""
    <div class="bates-shell">
      <.topbar />

      <section class="bates-summary">
        <.stat :for={s <- @stats} stat={s} />
      </section>

      <%= if @apps == [] do %>
        <p class="bates-empty">No applications configured.</p>
      <% else %>
        <section class="bates-apps">
          <.app_card :for={app <- @apps} app={app} />
        </section>
      <% end %>

      <footer class="bates-footer">
        <span>§ Bates</span>
        <span>{@apps |> length()} app{if length(@apps) == 1, do: "", else: "s"}</span>
      </footer>
    </div>
    """
  end

  attr :rest, :global

  defp topbar(assigns) do
    ~H"""
    <header class="bates-topbar" {@rest}>
      <.wordmark />
      <div class="bates-topbar__right">
        <span class="bates-pill">
          <span class="bates-pill__dot"></span>
          running on <span class="bates-pill__mono">*.test</span>
        </span>
      </div>
    </header>
    """
  end

  defp wordmark(assigns) do
    ~H"""
    <div class="bates-wordmark">
      <span class="bates-wordmark__name">Bates</span>
      <span class="bates-wordmark__tag">at your service</span>
    </div>
    """
  end

  attr :stat, :map, required: true

  defp stat(assigns) do
    ~H"""
    <div class={"bates-stat bates-stat--#{@stat.tone}"}>
      <div class="bates-stat__row">
        <span class="bates-stat__lamp-slot">
          <.status_lamp state={@stat.lamp} />
        </span>
        <span class="bates-stat__value">{@stat.value}</span>
        <span class="bates-stat__label">{@stat.label}</span>
      </div>
    </div>
    """
  end

  attr :state, :string, required: true

  defp status_lamp(assigns) do
    ~H"""
    <span class={"bates-lamp bates-lamp--#{@state}"} aria-hidden="true"></span>
    """
  end

  attr :app, :map, required: true

  defp app_card(assigns) do
    assigns =
      assigns
      |> assign(:lamp, lamp_state(assigns.app.status))
      |> assign(:error_count, service_error_count(assigns.app.services))
      |> assign(:all_up, assigns.app.status == "up")
      |> assign(:all_down, assigns.app.status == "down")

    ~H"""
    <article class="bates-app">
      <header class="bates-app__header">
        <div class="bates-app__title-group">
          <.status_lamp state={@lamp} />
          <h2 class="bates-app__title">{@app.name}</h2>
          <a class="bates-app__domain" href={"https://#{@app.hostname}"}>{@app.hostname}</a>
          <%= if @error_count > 0 do %>
            <span class="bates-app__error-tag">
              {@error_count} error{if @error_count > 1, do: "s", else: ""}
            </span>
          <% end %>
        </div>

        <div class="bates-app__actions">
          <button
            class="bates-btn bates-btn--ghost"
            phx-click="start"
            phx-value-name={@app.name}
            disabled={@all_up}
          >Start all</button>
          <%= if @all_up do %>
            <button
              class="bates-btn bates-btn--ghost"
              phx-click="restart"
              phx-value-name={@app.name}
            >Restart</button>
          <% end %>
          <button
            class="bates-btn bates-btn--ghost-destructive"
            phx-click="stop"
            phx-value-name={@app.name}
            disabled={@all_down}
          >Stop all</button>
        </div>
      </header>

      <div class="bates-services">
        <div class="bates-services__head">
          <div class="bates-services__cell">Service</div>
          <div class="bates-services__cell">Hostname</div>
          <div class="bates-services__cell">Status</div>
          <div class="bates-services__cell">Port</div>
        </div>
        <.service_row :for={svc <- @app.services} svc={svc} />
      </div>
    </article>
    """
  end

  attr :svc, :map, required: true

  defp service_row(assigns) do
    lamp = lamp_state(assigns.svc.status)

    assigns =
      assigns
      |> assign(:lamp, lamp)
      |> assign(:dim, assigns.svc.status in ["down", "crashed"])

    ~H"""
    <div class="bates-services__row">
      <div class="bates-services__cell bates-services__cell--name">{@svc.name}</div>
      <div class="bates-services__cell bates-services__cell--host">
        <%= if @svc.hostname do %>
          <a href={"https://#{@svc.hostname}"}>{@svc.hostname}</a>
        <% else %>
          <span class="bates-services__cell--dim">—</span>
        <% end %>
      </div>
      <div class="bates-services__cell">
        <span class={"bates-services__status bates-services__status--#{@lamp}"}>
          <.status_lamp state={@lamp} />
          {@svc.status}{if @svc.status == "starting", do: "…", else: ""}
        </span>
      </div>
      <div class={"bates-services__cell" <> if(@dim, do: " bates-services__cell--dim", else: "")}>
        <%= if @svc.port do %>
          :{@svc.port}
        <% else %>
          —
        <% end %>
      </div>
    </div>
    """
  end
end
