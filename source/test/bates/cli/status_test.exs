defmodule Bates.CLI.StatusTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bates.CLI.Status

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

  describe "run/0" do
    test "renders headers only when no processes are configured", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"processes":[]}))
      end)

      output = capture_io(fn -> assert Status.run() == :ok end)

      assert output =~ ~r/^NAME\s+HOSTNAME\s+STATUS\s+PORT/
      assert String.split(output, "\n", trim: true) |> length() == 1
    end

    test "renders a single-service app as one row", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/status", fn conn ->
        body =
          ~s({"processes":[{"name":"api","status":"down","services":[{"name":"api","hostname":"api.test","status":"down","port":null}]}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      output = capture_io(fn -> Status.run() end)
      lines = String.split(output, "\n", trim: true)

      assert length(lines) == 2
      assert Enum.at(lines, 1) =~ "api"
      assert Enum.at(lines, 1) =~ "api.test"
      assert Enum.at(lines, 1) =~ "down"
      assert Enum.at(lines, 1) =~ "—"
    end

    test "renders a multi-service app as a parent row plus indented children",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/status", fn conn ->
        body =
          ~s({"processes":[{"name":"myapp","status":"up","services":[) <>
            ~s({"name":"web","hostname":"myapp.test","status":"up","port":52341},) <>
            ~s({"name":"vite","hostname":"vite.myapp.test","status":"up","port":52342},) <>
            ~s({"name":"worker","hostname":null,"status":"up","port":null}) <>
            ~s(]}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      output = capture_io(fn -> Status.run() end)
      lines = String.split(output, "\n", trim: true)

      # header + parent + 3 services
      assert length(lines) == 5

      [_header, parent, web, vite, worker] = lines

      assert parent =~ "myapp"
      refute parent =~ "myapp.test"

      assert web =~ "  web"
      assert web =~ "myapp.test"
      assert web =~ "52341"

      assert vite =~ "  vite"
      assert vite =~ "vite.myapp.test"
      assert vite =~ "52342"

      assert worker =~ "  worker"
      assert worker =~ "—"
    end

    test "writes the canonical not-running message on transport error",
         %{bypass: bypass} do
      Bypass.down(bypass)

      stderr =
        capture_io(:stderr, fn ->
          assert Status.run() == 1
        end)

      assert stderr =~ "Bates is not running"
    end
  end

  describe "render/1" do
    test "renders empty list as headers only" do
      assert Status.render([]) =~ "NAME"
      assert String.split(Status.render([]), "\n", trim: true) |> length() == 1
    end

    test "matches the spec sample shape" do
      processes = [
        %{
          "name" => "myapp",
          "status" => "up",
          "services" => [
            %{
              "name" => "web",
              "hostname" => "myapp.test",
              "status" => "up",
              "port" => 52341
            },
            %{
              "name" => "vite",
              "hostname" => "vite.myapp.test",
              "status" => "up",
              "port" => 52342
            },
            %{
              "name" => "worker",
              "hostname" => nil,
              "status" => "up",
              "port" => nil
            }
          ]
        },
        %{
          "name" => "api",
          "status" => "down",
          "services" => [
            %{
              "name" => "api",
              "hostname" => "api.test",
              "status" => "down",
              "port" => nil
            }
          ]
        }
      ]

      output = Status.render(processes)
      lines = String.split(output, "\n", trim: true)

      assert hd(lines) =~ "NAME"
      assert hd(lines) =~ "HOSTNAME"
      assert hd(lines) =~ "STATUS"
      assert hd(lines) =~ "PORT"

      assert Enum.any?(lines, fn line -> line =~ ~r/^myapp\s/ end)
      assert Enum.any?(lines, fn line -> line =~ ~r/^  web\s/ end)
      assert Enum.any?(lines, fn line -> line =~ ~r/^api\s/ end)
    end
  end
end
