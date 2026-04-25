defmodule ConjureWeb.Plugs.AppRedirect do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    control_host = ConjureWeb.Endpoint.config(:url)[:host]

    if conn.host != control_host and String.ends_with?(conn.host, ".test") do
      app_name = conn.host |> String.replace(~r/\.test$/, "")

      conn
      |> redirect(to: "/loading/#{app_name}")
      |> halt()
    else
      conn
    end
  end
end
