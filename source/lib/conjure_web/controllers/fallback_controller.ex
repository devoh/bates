defmodule ConjureWeb.FallbackController do
  use ConjureWeb, :controller

  def index(conn, _params) do
    conn
    |> put_status(404)
    |> text("Not found")
  end
end
