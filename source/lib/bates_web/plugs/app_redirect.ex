defmodule BatesWeb.Plugs.AppRedirect do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    control_host = BatesWeb.Endpoint.config(:url)[:host]

    if conn.host != control_host and String.ends_with?(conn.host, ".test") do
      hostname_map = Bates.ProcessSupervisor.hostname_lookup()
      hostname = conn.host

      case Map.get(hostname_map, hostname) do
        nil ->
          conn
          |> put_status(404)
          |> Phoenix.Controller.text("Not found")
          |> halt()

        {app_name, service_name} ->
          conn
          |> redirect(external: "https://#{control_host}/loading/#{app_name}/#{service_name}")
          |> halt()
      end
    else
      conn
    end
  end
end
