defmodule BatesWeb.FallbackControllerTest do
  use BatesWeb.ConnCase

  alias Bates.{App, Service}

  test "redirects app domain to loading page", %{conn: conn} do
    config =
      {"testapp", ".",
       [
         %Service{
           name: "testapp",
           command: "sleep 999",
           port: nil,
           hostname: "testapp.test"
         }
       ]}

    start_supervised!({App, config})

    conn =
      %{conn | host: "testapp.test"}
      |> get("/")

    assert redirected_to(conn) == "https://bates.test/loading/testapp/testapp"
  end

  test "redirects custom hostname to loading page", %{conn: conn} do
    config =
      {"myapp", ".",
       [
         %Service{
           name: "web",
           command: "sleep 999",
           port: nil,
           hostname: "myapp.test"
         },
         %Service{
           name: "vite",
           command: "sleep 999",
           port: nil,
           hostname: "vite.myapp.test"
         }
       ]}

    start_supervised!({App, config})

    conn =
      %{conn | host: "vite.myapp.test"}
      |> get("/")

    assert redirected_to(conn) == "https://bates.test/loading/myapp/vite"
  end

  test "returns 404 on control domain", %{conn: conn} do
    conn =
      %{conn | host: "bates.test"}
      |> get("/nonexistent")

    assert conn.status == 404
  end

  test "returns 404 for unknown .test hostname", %{conn: conn} do
    conn =
      %{conn | host: "unknown.test"}
      |> get("/")

    assert conn.status == 404
  end
end
