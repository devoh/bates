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
    {:ok, _live, html} = live(conn, "/")

    # Only processes from config.toml may be present. If the process
    # list is empty (no config.toml), the empty state should display.
    # When config.toml exists, the table renders instead.
    names = Conjure.ProcessSupervisor.process_names()

    if names == [] do
      assert html =~ "No applications configured"
    else
      assert html =~ "Name"
      assert html =~ "Hostname"
    end
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

  defp assert_eventually(fun, attempts \\ 50) do
    if fun.() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(100)
        assert_eventually(fun, attempts - 1)
      else
        flunk("Condition not met after waiting")
      end
    end
  end
end
