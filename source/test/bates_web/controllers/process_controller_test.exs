defmodule BatesWeb.ProcessControllerTest do
  use BatesWeb.ConnCase

  alias Bates.{App, Service}

  defp single_service_config do
    {"testapp", ".", [
      %Service{
        name: "testapp",
        command: "elixir test/support/test_server.ex",
        port: nil,
        hostname: "testapp.test",
        middleware: ["port"]
      }
    ]}
  end

  defp start_app(config) do
    start_supervised!({App, config})
    assert_eventually(fn -> App.status("testapp") != "starting" end)
  end

  test "restart returns up after stopping and starting", %{conn: conn} do
    config = single_service_config()
    start_app(config)
    :ok = App.up("testapp")
    assert_eventually(fn -> App.status("testapp") == "up" end)

    conn = post(conn, "/processes/testapp/restart")

    assert %{"name" => "testapp", "status" => "up"} = json_response(conn, 200)
  end

  test "restart works when app is already stopped", %{conn: conn} do
    config = single_service_config()
    start_app(config)

    conn = post(conn, "/processes/testapp/restart")

    assert %{"name" => "testapp", "status" => "up"} = json_response(conn, 200)
  end

  test "logs returns per-service log lines", %{conn: conn} do
    config = single_service_config()
    start_app(config)
    :ok = App.up("testapp")
    assert_eventually(fn -> App.status("testapp") == "up" end)

    conn = get(conn, "/processes/testapp/logs")

    assert %{"name" => "testapp", "services" => services} = json_response(conn, 200)
    assert [%{"name" => "testapp", "lines" => lines}] = services
    assert is_list(lines)
  end

  test "logs returns empty lines when app has not started", %{conn: conn} do
    config = single_service_config()
    start_app(config)

    conn = get(conn, "/processes/testapp/logs")

    assert %{"name" => "testapp", "services" => services} = json_response(conn, 200)
    assert [%{"name" => "testapp", "lines" => []}] = services
  end
end
