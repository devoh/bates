defmodule BatesWeb.Plugs.AppRedirect do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    control_host = BatesWeb.Endpoint.config(:url)[:host]

    already_loading = match?(["loading" | _], conn.path_info)

    if conn.host != control_host and String.ends_with?(conn.host, ".test") and not already_loading do
      app_name = conn.host |> String.trim_trailing(".test") |> String.split(".") |> List.first()

      conn
      |> redirect(to: "/loading/#{app_name}")
      |> halt()
    else
      conn
    end
  end
end
