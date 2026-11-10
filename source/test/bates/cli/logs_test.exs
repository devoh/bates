defmodule Bates.CLI.LogsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bates.CLI.Logs

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

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  test "prints a single service's lines bare", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/processes/myapp/logs", fn conn ->
      assert conn.query_string == "lines=100"

      respond(conn, 200, %{
        name: "myapp",
        services: [%{name: "myapp", lines: ["one", "two"]}]
      })
    end)

    output = capture_io(fn -> assert Logs.run(["myapp"]) == :ok end)
    assert output == "one\ntwo\n"
  end

  test "prefixes lines with the service name for several services",
       %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/processes/myapp/logs", fn conn ->
      respond(conn, 200, %{
        name: "myapp",
        services: [
          %{name: "web", lines: ["listening"]},
          %{name: "worker", lines: ["working", "done"]}
        ]
      })
    end)

    output = capture_io(fn -> assert Logs.run(["myapp"]) == :ok end)
    assert output == "[web] listening\n[worker] working\n[worker] done\n"
  end

  test "requests one service with --lines", %{bypass: bypass} do
    Bypass.expect_once(
      bypass,
      "GET",
      "/processes/myapp/services/web/logs",
      fn conn ->
        assert conn.query_string == "lines=5"

        respond(conn, 200, %{
          name: "myapp",
          services: [%{name: "web", lines: ["ok"]}]
        })
      end
    )

    output =
      capture_io(fn ->
        assert Logs.run(["--lines", "5", "myapp:web"]) == :ok
      end)

    assert output == "ok\n"
  end

  test "resolves the application from the current directory",
       %{bypass: bypass} do
    {:ok, cwd} = File.cwd()

    Bypass.expect_once(bypass, "GET", "/apps/resolve", fn conn ->
      assert URI.decode_query(conn.query_string) == %{"path" => cwd}
      respond(conn, 200, %{name: "myapp", root: cwd})
    end)

    Bypass.expect_once(bypass, "GET", "/processes/myapp/logs", fn conn ->
      respond(conn, 200, %{
        name: "myapp",
        services: [%{name: "myapp", lines: ["here"]}]
      })
    end)

    output = capture_io(fn -> assert Logs.run([]) == :ok end)
    assert output == "here\n"
  end

  test "writes the reason to stderr on a 404", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/processes/ghost/logs", fn conn ->
      respond(conn, 404, %{
        name: "ghost",
        status: "unknown",
        reason: "unknown application: ghost"
      })
    end)

    stderr =
      capture_io(:stderr, fn -> assert Logs.run(["ghost"]) == 1 end)

    assert stderr == "unknown application: ghost\n"
  end

  test "rejects bad arguments with exit code 2" do
    for argv <- [
          ["a", "b"],
          ["--lines", "0"],
          ["--lines", "x"],
          ["--follow"],
          ["a:b:c"]
        ] do
      capture_io(:stderr, fn -> assert Logs.run(argv) == 2 end)
    end
  end
end
