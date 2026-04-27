defmodule BatesWeb.LoadingControllerTest do
  use BatesWeb.ConnCase

  alias Bates.{App, Service}

  defp service_config(name, command) do
    {name, ".", [
      %Service{
        name: name,
        command: command,
        port: nil,
        hostname: "#{name}.test"
      }
    ]}
  end

  test "redirects when app is already running", %{conn: conn} do
    config = service_config("myapp", "elixir test/support/test_server.ex")
    start_supervised!({App, config})
    :ok = App.up("myapp")

    assert_eventually(fn -> App.status("myapp") == "up" end)

    conn = get(conn, "/loading/myapp/myapp")

    assert redirected_to(conn) == "https://myapp.test"
  end

  test "blocks until app comes up then redirects", %{conn: conn} do
    config = service_config("myapp", "elixir test/support/test_server.ex")
    start_supervised!({App, config})

    conn = get(conn, "/loading/myapp/myapp")

    assert redirected_to(conn) == "https://myapp.test"
  end

  test "returns 502 when app crashes", %{conn: conn} do
    config = service_config("myapp", "exit 1")
    start_supervised!({App, config})

    conn = get(conn, "/loading/myapp/myapp")

    assert conn.status == 502
    assert conn.resp_body =~ "myapp crashed"
  end

  test "redirects to service hostname for multi-service app", %{conn: conn} do
    config = {"myapp", ".", [
      %Service{name: "web", command: "elixir test/support/test_server.ex", port: nil, hostname: "myapp.test"},
      %Service{name: "vite", command: "sleep 999", port: nil}
    ]}

    start_supervised!({App, config})

    conn = get(conn, "/loading/myapp/web")

    assert redirected_to(conn) == "https://myapp.test"
  end
end
