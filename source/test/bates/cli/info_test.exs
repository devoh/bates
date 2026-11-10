defmodule Bates.CLI.InfoTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bates.CLI.Info

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

  @status %{
    processes: [
      %{
        name: "myapp",
        root: "/work/myapp",
        status: "up",
        services: [
          %{name: "web", hostname: "myapp.test", status: "up", port: 52341},
          %{name: "worker", hostname: nil, status: "up", port: nil}
        ]
      },
      %{
        name: "api",
        root: "/work/api",
        status: "down",
        services: [
          %{name: "api", hostname: "api.test", status: "down", port: nil}
        ]
      }
    ]
  }

  defp expect_status(bypass) do
    Bypass.expect_once(bypass, "GET", "/status", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(@status))
    end)
  end

  test "prints the named application's root and service URLs",
       %{bypass: bypass} do
    expect_status(bypass)

    output = capture_io(fn -> assert Info.run("myapp") == :ok end)

    assert output == """
           name:   myapp
           root:   /work/myapp
           status: up
           services:
             web     https://myapp.test  up  52341
             worker                      up  —
           """
  end

  test "resolves the application from the current directory",
       %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/apps/resolve", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"name":"api","root":"/work/api"}))
    end)

    expect_status(bypass)

    output = capture_io(fn -> assert Info.run() == :ok end)
    assert output =~ "name:   api\n"
    assert output =~ "  api  https://api.test  down  —\n"
  end

  test "exits 1 for an unknown application", %{bypass: bypass} do
    expect_status(bypass)

    stderr = capture_io(:stderr, fn -> assert Info.run("ghost") == 1 end)
    assert stderr == "unknown application: ghost\n"
  end

  test "rejects a service name with exit code 2" do
    capture_io(:stderr, fn -> assert Info.run("myapp:web") == 2 end)
  end
end
