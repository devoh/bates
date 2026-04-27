defmodule BatesWeb.LoadingLiveTest do
  use BatesWeb.ConnCase

  alias Bates.{App, Service}

  defp single_service_config(name, opts \\ []) do
    command = Keyword.get(opts, :command, "sleep 999")

    {name, ".", [
      %Service{
        name: name,
        command: command,
        port: nil,
        hostname: "#{name}.test"
      }
    ]}
  end

  test "shows loading page when app is starting", %{conn: conn} do
    config = single_service_config("myapp")
    start_supervised!({App, config})

    {:ok, _live, html} = live(conn, "/loading/myapp")

    assert html =~ "Starting application"
  end

  test "redirects when app is already running", %{conn: conn} do
    config = single_service_config("myapp", command: "elixir test/support/test_server.ex")
    start_supervised!({App, config})
    :ok = App.up("myapp")

    assert_eventually(fn -> App.status("myapp") == "up" end)

    assert {:error, {:redirect, %{to: "https://myapp.test"}}} =
             live(conn, "/loading/myapp")
  end

  test "redirects when app comes up after mount", %{conn: conn} do
    {:ok, live, _html} = live(conn, "/loading/myapp")

    Phoenix.PubSub.broadcast(Bates.PubSub, "app:myapp", {:status, "up"})

    assert_redirect(live, "https://myapp.test")
  end

  test "loading page with hostname param redirects to that hostname", %{conn: conn} do
    config = {"myapp", ".", [
      %Service{name: "web", command: "sleep 999", port: nil, hostname: "myapp.test"},
      %Service{name: "vite", command: "sleep 999", port: nil, hostname: "vite.myapp.test"}
    ]}

    start_supervised!({App, config})

    {:ok, live, _html} = live(conn, "/loading/myapp?hostname=vite.myapp.test")

    # Simulate the vite service becoming ready
    Phoenix.PubSub.broadcast(
      Bates.PubSub,
      "service:myapp:vite",
      {:status, "up"}
    )

    assert_redirect(live, "https://vite.myapp.test")
  end

  test "loading page without hostname param redirects to app default", %{conn: conn} do
    config = single_service_config("myapp")
    start_supervised!({App, config})

    {:ok, live, _html} = live(conn, "/loading/myapp")

    Phoenix.PubSub.broadcast(Bates.PubSub, "app:myapp", {:status, "up"})

    assert_redirect(live, "https://myapp.test")
  end
end
