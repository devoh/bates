defmodule ConjureWeb.DashboardLiveTest do
  use ConjureWeb.ConnCase

  alias Conjure.Process, as: AppProcess

  test "renders process list with name, hostname, status, and port", %{conn: conn} do
    process = %AppProcess{name: "myapp", command: "sleep 999", root: "."}
    start_supervised!({AppProcess, process})

    {:ok, _live, html} = live(conn, "/")

    assert html =~ "myapp"
    assert html =~ "myapp.test"
    assert html =~ "down"
  end

  test "renders empty state when no processes configured", %{conn: conn} do
    for name <- Conjure.ProcessSupervisor.process_names() do
      case GenServer.whereis({:via, Registry, {Conjure.ProcessRegistry, name}}) do
        pid when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Conjure.ProcessSupervisor, pid)

        nil ->
          :ok
      end
    end

    {:ok, _live, html} = live(conn, "/")

    assert html =~ "No applications configured"
  end

  test "displays port number for process", %{conn: conn} do
    process = %AppProcess{name: "myapp", command: "sleep 999", root: "."}
    start_supervised!({AppProcess, process})

    {:ok, port} = AppProcess.port("myapp")

    {:ok, _live, html} = live(conn, "/")

    assert html =~ to_string(port)
  end

  test "updates status when process starts", %{conn: conn} do
    process = %AppProcess{
      name: "myapp",
      command: "elixir test/support/test_server.ex",
      root: "."
    }

    start_supervised!({AppProcess, process})

    {:ok, live, html} = live(conn, "/")
    assert html =~ "down"

    AppProcess.up("myapp")
    assert_eventually(fn -> AppProcess.status("myapp") == "up" end)

    html = render(live)
    assert html =~ "up"
  end

  test "shows start button for down process", %{conn: conn} do
    process = %AppProcess{name: "myapp", command: "sleep 999", root: "."}
    start_supervised!({AppProcess, process})

    {:ok, _live, html} = live(conn, "/")

    assert html =~ "Start"
  end

  test "shows stop and restart buttons for up process", %{conn: conn} do
    process = %AppProcess{
      name: "myapp",
      command: "elixir test/support/test_server.ex",
      root: "."
    }

    start_supervised!({AppProcess, process})
    :ok = AppProcess.up("myapp")
    assert_eventually(fn -> AppProcess.status("myapp") == "up" end)

    {:ok, _live, html} = live(conn, "/")

    assert html =~ "Stop"
    assert html =~ "Restart"
  end

  test "start event starts a process", %{conn: conn} do
    process = %AppProcess{
      name: "myapp",
      command: "elixir test/support/test_server.ex",
      root: "."
    }

    start_supervised!({AppProcess, process})

    {:ok, live, _html} = live(conn, "/")

    live |> element(~s(button[phx-value-name="myapp"]), "Start") |> render_click()

    assert_eventually(fn -> AppProcess.status("myapp") == "up" end)
  end

  test "stop event stops a process", %{conn: conn} do
    process = %AppProcess{
      name: "myapp",
      command: "elixir test/support/test_server.ex",
      root: "."
    }

    start_supervised!({AppProcess, process})
    :ok = AppProcess.up("myapp")
    assert_eventually(fn -> AppProcess.status("myapp") == "up" end)

    {:ok, live, _html} = live(conn, "/")

    live |> element("button", "Stop") |> render_click()

    assert_eventually(fn -> AppProcess.status("myapp") == "down" end)
  end

  test "restart transitions back to up, not crashed", %{conn: conn} do
    process = %AppProcess{
      name: "myapp",
      command: "elixir test/support/test_server.ex",
      root: "."
    }

    start_supervised!({AppProcess, process})
    :ok = AppProcess.up("myapp")
    assert_eventually(fn -> AppProcess.status("myapp") == "up" end)

    {:ok, live, _html} = live(conn, "/")

    live |> element(~s(button[phx-value-name="myapp"]), "Restart") |> render_click()

    # Should transition through starting back to up, never landing on crashed
    assert_eventually(fn -> AppProcess.status("myapp") == "up" end)
    refute AppProcess.status("myapp") == "crashed"
  end

  test "restart transitions through down and starting to up", %{conn: _conn} do
    process = %AppProcess{
      name: "myapp",
      command: "elixir test/support/test_server.ex",
      root: "."
    }

    start_supervised!({AppProcess, process})
    :ok = AppProcess.up("myapp")
    assert_eventually(fn -> AppProcess.status("myapp") == "up" end)

    :ok = AppProcess.down("myapp")
    assert AppProcess.status("myapp") == "down"

    :ok = AppProcess.up("myapp")
    assert_eventually(fn -> AppProcess.status("myapp") == "up" end)
  end
end
