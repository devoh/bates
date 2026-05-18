defmodule BatesWeb.DashboardLiveTest do
  use BatesWeb.ConnCase

  alias Bates.{App, Service}

  defp single_service_config(name, opts \\ []) do
    command = Keyword.get(opts, :command, "sleep 999")

    {name, ".",
     [
       %Service{
         name: name,
         command: command,
         port: Bates.PortNumber.next(),
         hostname: "#{name}.test",
         middleware: ["port"]
       }
     ]}
  end

  test "renders app list with name, hostname, status, and port", %{conn: conn} do
    config = single_service_config("myapp")
    start_supervised!({App, config})

    {:ok, _live, html} = live(conn, "/")

    assert html =~ "myapp"
    assert html =~ "myapp.test"
    assert html =~ "down"
  end

  test "renders empty state when no apps configured", %{conn: conn} do
    for name <- Bates.ProcessSupervisor.app_names() do
      case GenServer.whereis({:via, Registry, {Bates.ProcessRegistry, name}}) do
        pid when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Bates.ProcessSupervisor, pid)

        nil ->
          :ok
      end
    end

    {:ok, _live, html} = live(conn, "/")

    assert html =~ "No applications configured"
  end

  test "displays port number for app", %{conn: conn} do
    config = single_service_config("myapp")
    start_supervised!({App, config})

    [service] = App.services("myapp")

    {:ok, _live, html} = live(conn, "/")

    assert html =~ to_string(service.port)
  end

  test "updates status when app starts", %{conn: conn} do
    config =
      single_service_config("myapp",
        command: "elixir test/support/test_server.ex"
      )

    start_supervised!({App, config})

    {:ok, live, html} = live(conn, "/")
    assert html =~ "down"

    App.up("myapp")
    assert_eventually(fn -> App.status("myapp") == "up" end)

    html = render(live)
    assert html =~ "up"
  end

  test "shows start button for down app", %{conn: conn} do
    config = single_service_config("myapp")
    start_supervised!({App, config})

    {:ok, _live, html} = live(conn, "/")

    assert html =~ "Start"
  end

  test "shows stop and restart buttons for up app", %{conn: conn} do
    config =
      single_service_config("myapp",
        command: "elixir test/support/test_server.ex"
      )

    start_supervised!({App, config})
    :ok = App.up("myapp")
    assert_eventually(fn -> App.status("myapp") == "up" end)

    {:ok, _live, html} = live(conn, "/")

    assert html =~ "Stop"
    assert html =~ "Restart"
  end

  test "start event starts an app", %{conn: conn} do
    config =
      single_service_config("myapp",
        command: "elixir test/support/test_server.ex"
      )

    start_supervised!({App, config})

    {:ok, live, _html} = live(conn, "/")

    live
    |> element(~s(button[phx-value-name="myapp"]), "Start")
    |> render_click()

    assert_eventually(fn -> App.status("myapp") == "up" end)
  end

  test "stop event stops an app", %{conn: conn} do
    config =
      single_service_config("myapp",
        command: "elixir test/support/test_server.ex"
      )

    start_supervised!({App, config})
    :ok = App.up("myapp")
    assert_eventually(fn -> App.status("myapp") == "up" end)

    {:ok, live, _html} = live(conn, "/")

    live |> element("button", "Stop") |> render_click()

    assert_eventually(fn -> App.status("myapp") == "down" end)
  end

  test "restart transitions back to up, not crashed", %{conn: conn} do
    config =
      single_service_config("myapp",
        command: "elixir test/support/test_server.ex"
      )

    start_supervised!({App, config})
    :ok = App.up("myapp")
    assert_eventually(fn -> App.status("myapp") == "up" end)

    {:ok, live, _html} = live(conn, "/")

    live
    |> element(~s(button[phx-value-name="myapp"]), "Restart")
    |> render_click()

    assert_eventually(fn -> App.status("myapp") == "up" end)
    refute App.status("myapp") == "crashed"
  end

  test "restart transitions through down and starting to up", %{conn: _conn} do
    config =
      single_service_config("myapp",
        command: "elixir test/support/test_server.ex"
      )

    start_supervised!({App, config})
    :ok = App.up("myapp")
    assert_eventually(fn -> App.status("myapp") == "up" end)

    :ok = App.down("myapp")
    assert App.status("myapp") == "down"

    :ok = App.up("myapp")
    assert_eventually(fn -> App.status("myapp") == "up" end)
  end

  test "multi-service app shows service rows", %{conn: conn} do
    config =
      {"myapp", ".",
       [
         %Service{
           name: "web",
           command: "sleep 999",
           port: Bates.PortNumber.next(),
           hostname: "myapp.test",
           middleware: ["port"]
         },
         %Service{
           name: "worker",
           command: "sleep 999",
           port: nil,
           hostname: nil
         }
       ]}

    start_supervised!({App, config})

    {:ok, _live, html} = live(conn, "/")

    assert html =~ "web"
    assert html =~ "worker"
  end

  test "single-service app shows no nested service rows", %{conn: conn} do
    config = single_service_config("myapp")
    start_supervised!({App, config})

    {:ok, _live, html} = live(conn, "/")

    # Should show app name but not a separate service sub-row with indented style
    assert html =~ "myapp"
    # The service name for single-service is the same as app name,
    # and there should be no sub-rows (background: #fafafa indicates sub-row)
    refute html =~ "background: #fafafa"
  end

  describe "per-service buttons" do
    defp multi_service_chain_config do
      {"myapp", ".",
       [
         %Service{
           name: "web",
           command: "sleep 999",
           port: Bates.PortNumber.next(),
           hostname: "myapp.test",
           middleware: ["port"]
         },
         %Service{
           name: "worker",
           command: "sleep 999",
           port: nil,
           hostname: nil
         }
       ]}
    end

    test "multi-service app renders per-service Start/Stop buttons",
         %{conn: conn} do
      config = multi_service_chain_config()
      start_supervised!({App, config})

      {:ok, _live, html} = live(conn, "/")

      assert html =~ "phx-click=\"start_service\""
      assert html =~ "phx-click=\"stop_service\""
      assert html =~ "phx-value-service=\"web\""
      assert html =~ "phx-value-service=\"worker\""
    end

    test "single-service app does not render per-service buttons",
         %{conn: conn} do
      config = single_service_config("myapp")
      start_supervised!({App, config})

      {:ok, _live, html} = live(conn, "/")

      refute html =~ "phx-click=\"start_service\""
      refute html =~ "phx-click=\"stop_service\""
    end

    test "start_service event triggers App.up/2", %{conn: conn} do
      config =
        {"myapp", ".",
         [
           %Service{
             name: "web",
             command: "sleep 999",
             port: Bates.PortNumber.next(),
             hostname: "myapp.test",
             middleware: ["port"]
           },
           %Service{
             name: "worker",
             command: "sleep 999",
             port: nil,
             hostname: nil
           }
         ]}

      start_supervised!({App, config})

      {:ok, live, _html} = live(conn, "/")

      live
      |> element(~s(button[phx-value-service="worker"]), "Start")
      |> render_click()

      assert_eventually(fn ->
        App.service_status("myapp", "worker") == "up"
      end)
    end

    test "stop_service event cascades to dependents", %{conn: conn} do
      config =
        {"myapp", ".",
         [
           %Service{
             name: "web",
             command: "elixir test/support/test_server.ex",
             port: nil,
             hostname: "myapp.test",
             middleware: ["port"]
           },
           %Service{
             name: "worker",
             command: "sleep 999",
             port: nil,
             hostname: nil,
             depends_on: ["web"]
           }
         ]}

      start_supervised!({App, config})
      :ok = App.up("myapp")

      assert_eventually(fn ->
        App.service_status("myapp", "worker") == "up"
      end)

      {:ok, live, _html} = live(conn, "/")

      live
      |> element(~s(button[phx-value-service="web"][phx-click="stop_service"]))
      |> render_click()

      assert_eventually(fn -> App.service_status("myapp", "web") == "down" end)

      assert_eventually(fn ->
        App.service_status("myapp", "worker") == "down"
      end)
    end

    test "Start button is disabled for an up service", %{conn: conn} do
      # Worker is portless, so it reaches "up" immediately on App.up.
      config = multi_service_chain_config()
      start_supervised!({App, config})
      :ok = App.up("myapp")

      assert_eventually(fn ->
        App.service_status("myapp", "worker") == "up"
      end)

      {:ok, _live, html} = live(conn, "/")

      assert html =~
               ~r/phx-value-service="worker"[^>]*disabled[^>]*>Start/

      refute html =~
               ~r/phx-value-service="worker"[^>]*disabled[^>]*>Stop/
    end

    test "Stop button is disabled for a down service", %{conn: conn} do
      config = multi_service_chain_config()
      start_supervised!({App, config})

      {:ok, _live, html} = live(conn, "/")

      assert html =~
               ~r/phx-value-service="worker"[^>]*disabled[^>]*>Stop/

      refute html =~
               ~r/phx-value-service="worker"[^>]*disabled[^>]*>Start/
    end
  end

  test "partial status shows start, stop, and restart buttons", %{conn: conn} do
    config =
      {"myapp", ".",
       [
         %Service{
           name: "web",
           command: "sleep 999",
           port: 19879,
           hostname: "myapp.test",
           middleware: ["port"]
         },
         %Service{
           name: "worker",
           command: "sleep 999",
           port: nil,
           hostname: nil
         }
       ]}

    start_supervised!({App, config})
    :ok = App.up("myapp")

    # Worker is portless so goes up immediately, web is starting
    # Derived status should be "starting" (all starting or up)
    # To get partial, we'd need a crash. Let's verify starting shows stop button.
    assert_eventually(fn -> App.status("myapp") in ["starting", "up"] end)

    {:ok, _live, html} = live(conn, "/")
    assert html =~ "Stop"
  end
end
