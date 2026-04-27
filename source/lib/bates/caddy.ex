defmodule Bates.Caddy do
  use GenServer
  require Logger

  @caddy_command ~c"caddy run --adapter caddyfile -c -"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    case check_prerequisites() do
      :ok ->
        {:ok, %{pid: nil, os_pid: nil}, {:continue, :start_caddy}}

      {:error, reason} ->
        Logger.warning("Caddy not started: #{reason}")
        {:ok, %{pid: nil, os_pid: nil}}
    end
  end

  @impl GenServer
  def handle_continue(:start_caddy, state) do
    case start_caddy() do
      {:ok, pid, os_pid} ->
        {:noreply, %{state | pid: pid, os_pid: os_pid}}

      {:error, reason} ->
        Logger.error("Failed to start Caddy: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({stream, _os_pid, data}, state)
      when stream in [:stdout, :stderr] do
    Logger.info("[caddy] #{String.trim(data)}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _os_pid, :process, _pid, reason}, state) do
    Logger.warning("[caddy] Process exited: #{inspect(reason)}")
    {:noreply, %{state | pid: nil, os_pid: nil}}
  end

  # Helpers

  defp check_prerequisites do
    with :ok <- check_caddy_in_path(),
         :ok <- check_resolver_file() do
      :ok
    end
  end

  defp check_caddy_in_path do
    case System.find_executable("caddy") do
      nil -> {:error, "`caddy` not found in $PATH. Install with: brew install caddy"}
      _path -> :ok
    end
  end

  defp check_resolver_file do
    if File.exists?("/etc/resolver/test") do
      :ok
    else
      {:error, "/etc/resolver/test not found. Create with: sudo bash -c 'echo \"nameserver 127.0.0.1\" > /etc/resolver/test'"}
    end
  end

  defp start_caddy do
    caddyfile = generate_caddyfile()
    Logger.info("[caddy] Starting with generated Caddyfile")

    case :exec.run_link(@caddy_command, [:stdin, :stdout, :stderr, :monitor]) do
      {:ok, pid, os_pid} ->
        :ok = :exec.send(os_pid, caddyfile)
        :ok = :exec.send(os_pid, :eof)
        {:ok, pid, os_pid}

      error ->
        error
    end
  end

  defp generate_caddyfile do
    control_port = control_interface_port()

    service_blocks =
      for name <- Bates.ProcessSupervisor.app_names(),
          service <- Bates.App.services(name),
          service.hostname != nil do
        service_block(service.hostname, service.port, control_port)
      end

    blocks = [control_block(control_port) | service_blocks]
    Enum.join(blocks, "\n\n") <> "\n"
  end

  defp control_block(control_port) do
    """
    bates.test {
      tls internal
      reverse_proxy 127.0.0.1:#{control_port}
    }\
    """
  end

  defp service_block(hostname, port, control_port) do
    """
    #{hostname} {
      tls internal
      handle_errors {
        @502 expression `{err.status_code} == 502`
        handle @502 {
          reverse_proxy 127.0.0.1:#{control_port}
        }
      }
      reverse_proxy 127.0.0.1:#{port}
    }\
    """
  end

  defp control_interface_port do
    BatesWeb.Endpoint.config(:http)[:port] || 4080
  end
end
