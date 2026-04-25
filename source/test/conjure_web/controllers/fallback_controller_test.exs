defmodule ConjureWeb.FallbackControllerTest do
  use ConjureWeb.ConnCase

  test "redirects app domain to loading page", %{conn: conn} do
    conn =
      %{conn | host: "testapp.test"}
      |> get("/")

    assert redirected_to(conn) == "/loading/testapp"
  end

  test "does not redirect loading page on app domain", %{conn: conn} do
    conn =
      %{conn | host: "testapp.test"}
      |> get("/loading/testapp")

    assert conn.status == 200
  end

  test "returns 404 on control domain", %{conn: conn} do
    conn =
      %{conn | host: "conjure.test"}
      |> get("/nonexistent")

    assert conn.status == 404
  end
end
