defmodule Bates.CLI.RestartTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bates.CLI.Restart

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

  test "announces success on stdout when the daemon returns 200",
       %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/processes/myapp/restart", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"name":"myapp","status":"up"}))
    end)

    output = capture_io(fn -> assert Restart.run("myapp") == :ok end)
    assert output == "bates: restarted myapp\n"
  end

  test "writes the error field to stderr on a 422", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/processes/myapp/restart", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(422, ~s({"name":"myapp","error":"failed_to_restart"}))
    end)

    stderr =
      capture_io(:stderr, fn ->
        assert Restart.run("myapp") == 1
      end)

    assert stderr =~ "failed_to_restart"
  end

  test "writes the canonical not-running message on transport error",
       %{bypass: bypass} do
    Bypass.down(bypass)

    stderr =
      capture_io(:stderr, fn ->
        assert Restart.run("myapp") == 1
      end)

    assert stderr =~ "Bates is not running"
  end

  test "rejects per-service form with usage error" do
    stderr =
      capture_io(:stderr, fn ->
        assert Restart.run("myapp:web") == 2
      end)

    assert stderr =~ "does not support per-service form"
  end
end
