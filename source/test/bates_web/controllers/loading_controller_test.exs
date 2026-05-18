defmodule BatesWeb.LoadingControllerTest do
  use BatesWeb.ConnCase

  alias Bates.{App, Service}

  defp service_config(name, command) do
    {name, ".",
     [
       %Service{
         name: name,
         command: command,
         port: nil,
         hostname: "#{name}.test",
         middleware: ["port"]
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
         %Service{name: "vite", command: "sleep 999", port: nil}
       ]}

    start_supervised!({App, config})

    conn = get(conn, "/loading/myapp/web")

    assert redirected_to(conn) == "https://myapp.test"
  end

  test "renders the LiveView loading page for browser clients", %{conn: conn} do
    config = service_config("myapp", "sleep 999")
    start_supervised!({App, config})

    conn =
      conn
      |> put_req_header("accept", "text/html")
      |> get("/loading/myapp/myapp")

    body = html_response(conn, 200)
    assert body =~ "bates-loading__chain"
    assert body =~ "myapp"
  end

  describe "paused" do
    test "browser hit on paused app renders the paused LiveView",
         %{conn: conn} do
      config = service_config("myapp", "sleep 999")
      start_supervised!({App, config})
      :ok = App.down("myapp")
      assert App.paused?("myapp")

      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get("/loading/myapp/myapp")

      body = html_response(conn, 200)
      assert body =~ "is paused"
      assert body =~ "myapp"
      assert body =~ "resume=true"
    end

    test "non-browser hit on paused app returns 503 JSON", %{conn: conn} do
      config = service_config("myapp", "sleep 999")
      start_supervised!({App, config})
      :ok = App.down("myapp")
      assert App.paused?("myapp")

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/loading/myapp/myapp")

      body = json_response(conn, 503)
      assert body["app"] == "myapp"
      assert body["status"] == "paused"
      assert body["reason"] =~ "paused"
    end

    test "resume=true falls through to the normal loading flow",
         %{conn: conn} do
      config = service_config("myapp", "elixir test/support/test_server.ex")
      start_supervised!({App, config})
      :ok = App.down("myapp")
      assert App.paused?("myapp")

      conn = get(conn, "/loading/myapp/myapp?resume=true")

      assert redirected_to(conn) == "https://myapp.test"
      refute App.paused?("myapp")
    end
  end

  test "returns 502 when an upstream dependency crashes", %{conn: conn} do
    config =
      {"myapp", ".",
       [
         %Service{
           name: "vite",
           command: "exit 1",
           port: nil,
           hostname: "vite.myapp.test",
           middleware: ["port"]
         },
         %Service{
           name: "web",
           command: "elixir test/support/test_server.ex",
           port: nil,
           hostname: "myapp.test",
           middleware: ["port"],
           depends_on: ["vite"]
         }
       ]}

    start_supervised!({App, config})

    # Web waits on vite. Vite's command exits non-zero, the app reaches
    # `crashed`, and the loading page bails on the app-level broadcast
    # rather than spinning until its own timeout.
    conn = get(conn, "/loading/myapp/web")

    assert conn.status == 502
    assert conn.resp_body =~ "myapp crashed"
  end
end
