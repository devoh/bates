defmodule ConjureWeb.FallbackController do
  use ConjureWeb, :controller

  def index(conn, _params) do
    host = get_req_header(conn, "host") |> List.first("")
    app_name = host |> String.replace(~r/\.test(:\d+)?$/, "")

    if app_name != "" and app_name != host do
      redirect(conn, to: "/loading/#{app_name}")
    else
      conn
      |> put_status(404)
      |> text("Not found")
    end
  end
end
