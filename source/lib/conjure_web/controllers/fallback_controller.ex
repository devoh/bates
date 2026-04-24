defmodule ConjureWeb.FallbackController do
  use ConjureWeb, :controller

  def index(conn, _params) do
    control_host = ConjureWeb.Endpoint.config(:url)[:host]

    if conn.host != control_host do
      app_name = conn.host |> String.replace(~r/\.test$/, "")
      redirect(conn, to: "/loading/#{app_name}")
    else
      conn
      |> put_status(404)
      |> text("Not found")
    end
  end
end
