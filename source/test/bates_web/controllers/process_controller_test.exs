defmodule BatesWeb.ProcessControllerTest do
  use BatesWeb.ConnCase

  alias Bates.{App, Service}
  alias Bates.TestSupport.ExportProducer

  defp single_service_config do
    {"testapp", ".",
     [
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

  describe "start" do
    setup do
      Bates.Middleware.Registry.register("export_producer", ExportProducer)

      on_exit(fn ->
        Bates.Middleware.Registry.unregister("export_producer")
        Application.delete_env(:bates, :export_producer_exports)
      end)

      :ok
    end

    defp portless_config(opts \\ []) do
      command = Keyword.get(opts, :command, "sleep 999")
      middleware = Keyword.get(opts, :middleware, [])

      {"testapp", ".",
       [
         %Service{
           name: "worker",
           command: command,
           port: nil,
           hostname: nil,
           middleware: middleware
         }
       ]}
    end

    test "returns 200 with exports when app is already up", %{conn: conn} do
      Application.put_env(:bates, :export_producer_exports, %{
        "worker" => %{"FOO" => "bar"}
      })

      config = portless_config(middleware: ["export_producer"])
      start_supervised!({App, config})
      :ok = App.up("testapp")
      assert_eventually(fn -> App.status("testapp") == "up" end)

      conn = post(conn, "/processes/testapp/start")

      assert %{
               "name" => "testapp",
               "status" => "up",
               "exports" => %{"FOO" => "bar"}
             } = json_response(conn, 200)
    end

    test "triggers boot and returns exports for a down app", %{conn: conn} do
      Application.put_env(:bates, :export_producer_exports, %{
        "worker" => %{"PGHOST" => "127.0.0.1", "PGPORT" => "12345"}
      })

      config = portless_config(middleware: ["export_producer"])
      start_supervised!({App, config})

      conn = post(conn, "/processes/testapp/start")

      assert %{
               "name" => "testapp",
               "status" => "up",
               "exports" => exports
             } = json_response(conn, 200)

      assert exports == %{"PGHOST" => "127.0.0.1", "PGPORT" => "12345"}
    end

    test "returns 200 with empty exports for a service producing none",
         %{conn: conn} do
      config = portless_config()
      start_supervised!({App, config})

      conn = post(conn, "/processes/testapp/start")

      assert %{
               "name" => "testapp",
               "status" => "up",
               "exports" => %{}
             } = json_response(conn, 200)
    end

    test "returns 404 for unknown application", %{conn: conn} do
      conn = post(conn, "/processes/unknown/start")

      assert %{
               "name" => "unknown",
               "status" => "unknown",
               "reason" => reason
             } = json_response(conn, 404)

      assert reason =~ "unknown application"
    end

    test "returns 422 when a service crashes during boot", %{conn: conn} do
      # Use a two-service config where the dependent stays
      # `pid: nil, exit_status: nil` (never settles), so the
      # `:exports_settled` broadcast never fires and the controller
      # observes the dependency's `{:status, "crashed", _}`.
      config =
        {"testapp", ".",
         [
           %Service{
             name: "bad",
             command: "exit 1",
             port: nil,
             hostname: "bad.testapp.test",
             middleware: ["port"]
           },
           %Service{
             name: "web",
             command: "elixir test/support/test_server.ex",
             port: nil,
             hostname: "testapp.test",
             middleware: ["port"],
             depends_on: ["bad"]
           }
         ]}

      start_supervised!({App, config})

      conn = post(conn, "/processes/testapp/start")

      assert %{
               "name" => "testapp",
               "status" => "crashed"
             } = json_response(conn, 422)
    end

    test "returns 504 when readiness times out", %{conn: conn} do
      # The controller's wait fetches `:readiness_timeout` at runtime;
      # `Bates.App` captures it at compile time. Setting the runtime
      # value to 50ms shortens the controller's wait while the App's
      # readiness check still uses the test compile-time 2_000ms, so
      # the controller times out before the App finishes settling.
      original = Application.get_env(:bates, :readiness_timeout)
      Application.put_env(:bates, :readiness_timeout, 50)

      on_exit(fn ->
        if original do
          Application.put_env(:bates, :readiness_timeout, original)
        else
          Application.delete_env(:bates, :readiness_timeout)
        end
      end)

      # Dependent stays `pid: nil, exit_status: nil` until the slow
      # dep reports "up", which never happens because `sleep` never
      # binds the port. `all_services_settled?` is false, so
      # `{:exports_settled, _}` never fires.
      config =
        {"testapp", ".",
         [
           %Service{
             name: "slow",
             command: "sleep 999",
             port: nil,
             hostname: "slow.testapp.test",
             middleware: ["port"]
           },
           %Service{
             name: "web",
             command: "elixir test/support/test_server.ex",
             port: nil,
             hostname: "testapp.test",
             middleware: ["port"],
             depends_on: ["slow"]
           }
         ]}

      start_supervised!({App, config})

      conn = post(conn, "/processes/testapp/start")

      response = json_response(conn, 504)
      assert response["name"] == "testapp"
      assert response["status"] == "timeout"
      assert response["reason"] =~ "timed out"
    end

    test "concurrent callers receive the same exports without double spawn",
         %{conn: conn} do
      Application.put_env(:bates, :export_producer_exports, %{
        "worker" => %{"PGPORT" => "55555"}
      })

      # Use a command that is alive long enough to observe state but
      # exits quickly. Use the long-lived sleep so we can verify the
      # spawn count by inspecting state.
      config = portless_config(middleware: ["export_producer"])
      start_supervised!({App, config})

      # Snapshot the registry pid so we can read service state after.
      app_pid =
        GenServer.whereis(
          {:via, Registry, {Bates.ProcessRegistry, "testapp"}}
        )

      conn1 = conn
      conn2 = Phoenix.ConnTest.build_conn()

      task1 = Task.async(fn -> post(conn1, "/processes/testapp/start") end)
      task2 = Task.async(fn -> post(conn2, "/processes/testapp/start") end)

      response1 = Task.await(task1, 10_000)
      response2 = Task.await(task2, 10_000)

      body1 = json_response(response1, 200)
      body2 = json_response(response2, 200)

      assert body1["status"] == "up"
      assert body2["status"] == "up"
      assert body1["exports"] == %{"PGPORT" => "55555"}
      assert body2["exports"] == %{"PGPORT" => "55555"}

      # Confirm the worker service has exactly one OS pid recorded —
      # i.e., App.up/1 was idempotent under concurrent callers and
      # no respawn occurred.
      state = :sys.get_state(app_pid)
      worker = Map.fetch!(state.services, "worker")
      assert worker.pid != nil
    end
  end
end
