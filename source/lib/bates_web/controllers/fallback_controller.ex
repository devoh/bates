defmodule BatesWeb.FallbackController do
  use BatesWeb, :controller

  def index(conn, _params) do
    conn
    |> put_status(404)
    |> text("Not found")
  end
end
