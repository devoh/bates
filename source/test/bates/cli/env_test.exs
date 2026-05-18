defmodule Bates.CLI.EnvTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bates.CLI.Env

  describe "run/1" do
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

    test "emits exports in sorted order on a 200 with status \"up\"",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/processes/myapp/start", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"name":"myapp","status":"up","exports":{"PGPORT":"52345","PGHOST":"127.0.0.1"}})
        )
      end)

      {stdout, stderr_and_result} =
        with_captured_output(fn -> Env.run("myapp") end)

      assert stdout ==
               "export PGHOST='127.0.0.1'\nexport PGPORT='52345'\n"

      assert stderr_and_result.stderr == ""
      assert stderr_and_result.result == :ok
    end

    test "writes a stderr announcement when status is anything but \"up\"",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/processes/myapp/start", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"name":"myapp","status":"starting","exports":{}})
        )
      end)

      {_stdout, %{stderr: stderr, result: result}} =
        with_captured_output(fn -> Env.run("myapp") end)

      assert stderr =~ "bates: started myapp"
      assert result == :ok
    end

    test "writes the response reason to stderr on a non-2xx",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/processes/myapp/start", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          422,
          ~s({"name":"myapp","status":"crashed","reason":"boom"})
        )
      end)

      {_stdout, %{stderr: stderr, result: result}} =
        with_captured_output(fn -> Env.run("myapp") end)

      assert stderr =~ "boom"
      assert result == 1
    end

    test "writes the canonical not-running message on transport error",
         %{bypass: bypass} do
      Bypass.down(bypass)

      {_stdout, %{stderr: stderr, result: result}} =
        with_captured_output(fn -> Env.run("myapp") end)

      assert stderr =~ "Bates is not running"
      assert result == 1
    end

    test "short-circuits without an HTTP call when `BATES_APP` matches",
         %{bypass: bypass} do
      # Bring the bypass down so any HTTP call would surface as the
      # "Bates is not running" stderr message, which the assertions catch.
      Bypass.down(bypass)

      System.put_env("BATES_APP", "myapp")
      on_exit(fn -> System.delete_env("BATES_APP") end)

      {stdout, %{stderr: stderr, result: result}} =
        with_captured_output(fn -> Env.run("myapp") end)

      assert stdout == ""
      assert stderr == ""
      assert result == :ok
    end

    test "still calls the daemon when `BATES_APP` is set for a different app",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/processes/myapp/start", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"name":"myapp","status":"up","exports":{}})
        )
      end)

      System.put_env("BATES_APP", "otherapp")
      on_exit(fn -> System.delete_env("BATES_APP") end)

      {_stdout, %{result: result}} =
        with_captured_output(fn -> Env.run("myapp") end)

      assert result == :ok
    end

    defp with_captured_output(fun) do
      parent = self()

      stdout =
        capture_io(fn ->
          stderr =
            capture_io(:stderr, fn ->
              result = fun.()
              send(parent, {:done, result})
            end)

          send(parent, {:stderr, stderr})
        end)

      receive do
        {:stderr, stderr} ->
          receive do
            {:done, result} -> {stdout, %{stderr: stderr, result: result}}
          after
            0 -> {stdout, %{stderr: stderr, result: nil}}
          end
      after
        0 -> {stdout, %{stderr: "", result: nil}}
      end
    end
  end

  describe "format_export/2" do
    test "wraps a string value in single quotes" do
      assert Env.format_export("PGHOST", "127.0.0.1") ==
               "export PGHOST='127.0.0.1'"
    end

    test "escapes embedded single quotes with the POSIX dance" do
      assert Env.format_export("MSG", "it's") ==
               "export MSG='it'\\''s'"
    end

    test "stringifies non-string values" do
      assert Env.format_export("PGPORT", 52345) ==
               "export PGPORT='52345'"
    end
  end

  describe "escape/1" do
    test "leaves values without single quotes alone" do
      assert Env.escape("plain value") == "plain value"
    end

    test "escapes single quotes with the close-escape-open dance" do
      assert Env.escape("it's") == "it'\\''s"
    end

    test "escapes multiple single quotes" do
      assert Env.escape("a'b'c") == "a'\\''b'\\''c"
    end
  end

  describe "emit_exports/1" do
    test "writes one export line per key in sorted order" do
      output =
        capture_io(fn ->
          Env.emit_exports(%{"PGPORT" => "52345", "PGHOST" => "127.0.0.1"})
        end)

      assert output ==
               "export PGHOST='127.0.0.1'\nexport PGPORT='52345'\n"
    end

    test "writes nothing for an empty map" do
      output = capture_io(fn -> Env.emit_exports(%{}) end)
      assert output == ""
    end
  end
end
