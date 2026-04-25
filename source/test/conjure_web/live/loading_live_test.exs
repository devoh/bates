defmodule ConjureWeb.LoadingLiveTest do
  use ConjureWeb.ConnCase

  test "shows loading page when process is starting", %{conn: conn} do
    process = %Conjure.Process{name: "myapp", command: "sleep 999", root: "."}
    start_supervised!({Conjure.Process, process})

    {:ok, _live, html} = live(conn, "/loading/myapp")

    assert html =~ "Starting application"
  end

  test "redirects when process is already running", %{conn: conn} do
    process = %Conjure.Process{
      name: "myapp",
      command: "elixir test/support/test_server.ex",
      root: "."
    }

    start_supervised!({Conjure.Process, process})
    :ok = Conjure.Process.up("myapp")

    # Wait for the TCP readiness check to pass
    assert_eventually(fn -> Conjure.Process.status("myapp") == "up" end)

    assert {:error, {:redirect, %{to: "https://myapp.test"}}} =
             live(conn, "/loading/myapp")
  end

  test "redirects when process comes up after mount", %{conn: conn} do
    {:ok, live, _html} = live(conn, "/loading/myapp")

    Phoenix.PubSub.broadcast(Conjure.PubSub, "process:myapp", {:status, "up"})

    assert_redirect(live, "https://myapp.test")
  end
end
