defmodule BatesWeb.Plugs.AppRedirect do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    control_host = BatesWeb.Endpoint.config(:url)[:host]

    already_loading = match?(["loading" | _], conn.path_info)

    if conn.host != control_host and String.ends_with?(conn.host, ".test") and not already_loading do
      hostname_map = Bates.ProcessSupervisor.hostname_lookup()
      hostname = conn.host

      case Map.get(hostname_map, hostname) do
        nil ->
          conn
          |> put_status(404)
          |> Phoenix.Controller.text("Not found")
          |> halt()

        app_name ->
          redirect_path =
            if hostname == "#{app_name}.test" do
              "/loading/#{app_name}"
            else
              "/loading/#{app_name}?hostname=#{hostname}"
            end

          conn
          |> redirect(to: redirect_path)
          |> halt()
      end
    else
      conn
    end
  end
end
