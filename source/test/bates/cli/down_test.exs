defmodule Bates.CLI.DownTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bates.CLI.Down

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

  describe "per-service" do
    test "announces success with empty cascade", %{bypass: bypass} do
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

      output = capture_io(fn -> assert Down.run("myapp:web") == :ok end)
      assert output == "bates: stopped myapp:web\n"
    end

    test "appends cascaded list to the success line", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/processes/myapp/services/postgresql/stop",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            ~s({"app":"myapp","service":"postgresql","status":"down","cascaded":[{"service":"web","status":"down"},{"service":"worker","status":"down"}]})
          )
        end
      )

      output =
        capture_io(fn -> assert Down.run("myapp:postgresql") == :ok end)

      assert output ==
               "bates: stopped myapp:postgresql (also stopped: web, worker)\n"
    end

    test "writes the reason on a per-service 404", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/processes/myapp/services/missing/stop",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            404,
            ~s({"app":"myapp","service":"missing","status":"unknown","reason":"unknown service: missing"})
          )
        end
      )

      stderr =
        capture_io(:stderr, fn ->
          assert Down.run("myapp:missing") == 1
        end)

      assert stderr =~ "unknown service: missing"
    end
  end

  describe "target parsing" do
    test "rejects an empty name" do
      stderr =
        capture_io(:stderr, fn ->
          assert Down.run("") == 2
        end)

      assert stderr =~ "invalid target"
    end

    test "rejects a leading colon" do
      stderr =
        capture_io(:stderr, fn ->
          assert Down.run(":web") == 2
        end)

      assert stderr =~ "invalid target"
    end

    test "rejects a trailing colon" do
      stderr =
        capture_io(:stderr, fn ->
          assert Down.run("myapp:") == 2
        end)

      assert stderr =~ "invalid target"
    end

    test "rejects more than one colon" do
      stderr =
        capture_io(:stderr, fn ->
          assert Down.run("a:b:c") == 2
        end)

      assert stderr =~ "invalid target"
    end
  end
end
