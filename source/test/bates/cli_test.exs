defmodule Bates.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  describe "usage" do
    test "no arguments writes multi-line usage to stderr and returns exit code 2" do
      {output, exit_code} = run_dispatch([])

      assert exit_code == 2
      assert output =~ "Usage:"
      assert output =~ "bates setup"
      assert output =~ "bates status"
      assert output =~ "bates up [<name>]"
      assert output =~ "bates down [<name>]"
      assert output =~ "bates restart [<name>]"
      assert output =~ "bates env [<name>]"
    end

    test "unknown subcommand writes usage and returns exit code 2" do
      {output, exit_code} = run_dispatch(["bogus"])

      assert exit_code == 2
      assert output =~ "Usage:"
    end

    test "`setup` with extra args writes usage and returns exit code 2" do
      {output, exit_code} = run_dispatch(["setup", "extra"])
      assert exit_code == 2
      assert output =~ "Usage:"
    end

    test "`status` with extra args writes usage and returns exit code 2" do
      {output, exit_code} = run_dispatch(["status", "extra"])
      assert exit_code == 2
      assert output =~ "Usage:"
    end
  end

  describe "dispatch routing" do
    setup do
      bypass = Bypass.open()

      Application.put_env(
        :bates,
        :api_base_url,
        "http://localhost:#{bypass.port}"
      )

      on_exit(fn -> Application.delete_env(:bates, :api_base_url) end)
      {:ok, bypass: bypass}
    end

    test "routes `up <name>` to Bates.CLI.Up", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/processes/myapp/start", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name":"myapp","status":"up"}))
      end)

      output =
        capture_io(fn -> assert Bates.CLI.dispatch(["up", "myapp"]) == :ok end)

      assert output =~ "started myapp"
    end

    test "routes `down <name>` to Bates.CLI.Down", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/processes/myapp/stop", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name":"myapp","status":"down"}))
      end)

      output =
        capture_io(fn ->
          assert Bates.CLI.dispatch(["down", "myapp"]) == :ok
        end)

      assert output =~ "stopped myapp"
    end

    test "routes `restart <name>` to Bates.CLI.Restart", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/processes/myapp/restart", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name":"myapp","status":"up"}))
      end)

      output =
        capture_io(fn ->
          assert Bates.CLI.dispatch(["restart", "myapp"]) == :ok
        end)

      assert output =~ "restarted myapp"
    end

    test "routes `status` to Bates.CLI.Status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"processes":[]}))
      end)

      output =
        capture_io(fn -> assert Bates.CLI.dispatch(["status"]) == :ok end)

      assert output =~ "NAME"
    end

    test "resolves `env` (no arg) via /apps/resolve, then posts to that app",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/apps/resolve", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name":"myapp","root":"/Users/me/myapp"}))
      end)

      Bypass.expect_once(bypass, "POST", "/processes/myapp/env", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name":"myapp","status":"up","exports":{}}))
      end)

      capture_io(fn -> assert Bates.CLI.dispatch(["env"]) == :ok end)
    end

    test "writes the resolve error to stderr when the cwd has no app",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/apps/resolve", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          404,
          ~s({"status":"unknown","reason":"no application matches /tmp/elsewhere"})
        )
      end)

      {output, exit_code} = run_dispatch(["env"])

      assert exit_code == 1
      assert output =~ "no application matches"
    end

    test "resolves `up :service` to the cwd app then starts that service",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/apps/resolve", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name":"myapp","root":"/Users/me/myapp"}))
      end)

      Bypass.expect_once(
        bypass,
        "POST",
        "/processes/myapp/services/web/start",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            ~s({"app":"myapp","service":"web","status":"up"})
          )
        end
      )

      output =
        capture_io(fn -> assert Bates.CLI.dispatch(["up", ":web"]) == :ok end)

      assert output =~ "started myapp:web"
    end

    test "resolves `down :service` to the cwd app then stops that service",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/apps/resolve", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name":"myapp","root":"/Users/me/myapp"}))
      end)

      Bypass.expect_once(
        bypass,
        "POST",
        "/processes/myapp/services/web/stop",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            ~s({"app":"myapp","service":"web","status":"down","cascaded":[]})
          )
        end
      )

      output =
        capture_io(fn -> assert Bates.CLI.dispatch(["down", ":web"]) == :ok end)

      assert output =~ "stopped myapp:web"
    end
  end

  defp run_dispatch(argv) do
    parent = self()

    output =
      capture_io(:stderr, fn ->
        result = Bates.CLI.dispatch(argv)
        send(parent, {:exit_code, result})
      end)

    receive do
      {:exit_code, code} -> {output, code}
    after
      0 -> {output, nil}
    end
  end
end
