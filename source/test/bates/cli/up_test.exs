defmodule Bates.CLI.UpTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bates.CLI.Up

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
    Bypass.expect_once(bypass, "POST", "/processes/myapp/start", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"name":"myapp","status":"up"}))
    end)

    output = capture_io(fn -> assert Up.run("myapp") == :ok end)
    assert output == "bates: started myapp\n"
  end

  test "writes the response reason to stderr on a 422", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/processes/myapp/start", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        422,
        ~s({"name":"myapp","status":"crashed","reason":"boom"})
      )
    end)

    stderr =
      capture_io(:stderr, fn ->
        assert Up.run("myapp") == 1
      end)

    assert stderr =~ "boom"
  end

  test "writes the response reason on a 404", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/processes/ghost/start", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        404,
        ~s({"name":"ghost","status":"unknown","reason":"unknown application: ghost"})
      )
    end)

    stderr =
      capture_io(:stderr, fn ->
        assert Up.run("ghost") == 1
      end)

    assert stderr =~ "unknown application: ghost"
  end

  test "writes the canonical not-running message on transport error",
       %{bypass: bypass} do
    Bypass.down(bypass)

    stderr =
      capture_io(:stderr, fn ->
        assert Up.run("myapp") == 1
      end)

    assert stderr =~ "Bates is not running"
  end

  describe "per-service" do
    test "POSTs to the per-service path on success", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/processes/myapp/services/web/start",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            ~s({"app":"myapp","service":"web","status":"up","port":3001,"hostname":"myapp.test"})
          )
        end
      )

      output = capture_io(fn -> assert Up.run("myapp:web") == :ok end)
      assert output == "bates: started myapp:web\n"
    end

    test "writes the reason on a per-service 404", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/processes/myapp/services/web/start",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            404,
            ~s({"app":"myapp","service":"web","status":"unknown","reason":"unknown service: web"})
          )
        end
      )

      stderr =
        capture_io(:stderr, fn ->
          assert Up.run("myapp:web") == 1
        end)

      assert stderr =~ "unknown service: web"
    end

    test "writes the reason on a per-service 422", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/processes/myapp/services/web/start",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            422,
            ~s({"app":"myapp","service":"web","status":"crashed","reason":"boom"})
          )
        end
      )

      stderr =
        capture_io(:stderr, fn ->
          assert Up.run("myapp:web") == 1
        end)

      assert stderr =~ "boom"
    end
  end

  describe "target parsing" do
    test "rejects an empty name" do
      stderr =
        capture_io(:stderr, fn ->
          assert Up.run("") == 2
        end)

      assert stderr =~ "invalid target"
    end

    test "rejects a trailing colon" do
      stderr =
        capture_io(:stderr, fn ->
          assert Up.run("myapp:") == 2
        end)

      assert stderr =~ "invalid target"
    end

    test "rejects more than one colon" do
      stderr =
        capture_io(:stderr, fn ->
          assert Up.run("a:b:c") == 2
        end)

      assert stderr =~ "invalid target"
    end
  end
end
