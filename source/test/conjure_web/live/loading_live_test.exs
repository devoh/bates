defmodule ConjureWeb.LoadingLiveTest do
  use ConjureWeb.ConnCase

  test "redirects when process starts during mount", %{conn: conn} do
    process = %Conjure.Process{name: "myapp", command: "sleep 999", root: "."}
    start_supervised!({Conjure.Process, process})

    assert {:error, {:redirect, %{to: "https://myapp.test"}}} =
             live(conn, "/loading/myapp")
  end

  test "redirects when process is already running", %{conn: conn} do
    process = %Conjure.Process{name: "myapp", command: "sleep 999", root: "."}
    start_supervised!({Conjure.Process, process})
    :ok = Conjure.Process.up("myapp")

    assert {:error, {:redirect, %{to: "https://myapp.test"}}} =
             live(conn, "/loading/myapp")
  end

  test "redirects when process comes up after mount", %{conn: conn} do
    {:ok, live, _html} = live(conn, "/loading/myapp")

    Phoenix.PubSub.broadcast(Conjure.PubSub, "process:myapp", {:status, "up"})

    assert_redirect(live, "https://myapp.test")
  end
end
