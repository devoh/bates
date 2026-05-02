defmodule Bates.CLI.DownTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bates.CLI.Down

  setup do
    bypass = Bypass.open()
    Application.put_env(:bates, :api_base_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:bates, :api_base_url) end)
    {:ok, bypass: bypass}
  end

  test "announces success on stdout when the daemon returns 200",
       %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/processes/myapp/stop", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"name":"myapp","status":"down"}))
    end)

    output = capture_io(fn -> assert Down.run("myapp") == :ok end)
    assert output == "bates: stopped myapp\n"
  end

  test "writes the error field to stderr on a 422", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/processes/myapp/stop", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(422, ~s({"name":"myapp","error":"not_running"}))
    end)

    stderr =
      capture_io(:stderr, fn ->
        assert Down.run("myapp") == 1
      end)

    assert stderr =~ "not_running"
  end

  test "writes the canonical not-running message on transport error",
       %{bypass: bypass} do
    Bypass.down(bypass)

    stderr =
      capture_io(:stderr, fn ->
        assert Down.run("myapp") == 1
      end)

    assert stderr =~ "Bates is not running"
  end
end
