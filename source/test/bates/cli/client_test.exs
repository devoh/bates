defmodule Bates.CLI.ClientTest do
  use ExUnit.Case, async: false

  alias Bates.CLI.Client

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

  describe "get/2" do
    test "decodes a JSON object body to a map", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"processes":[]}))
      end)

      assert {:ok, 200, %{"processes" => []}} = Client.get("/status")
    end

    test "returns an empty map for an empty body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/status", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, 204, %{}} = Client.get("/status")
    end

    test "returns the status code on a non-2xx response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"error":"boom"}))
      end)

      assert {:ok, 500, %{"error" => "boom"}} = Client.get("/status")
    end

    test "returns a transport error when the server is unreachable",
         %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, reason} = Client.get("/status")

      assert match?({:failed_connect, _}, reason) or
               reason == :nxdomain
    end
  end

  describe "post/3" do
    test "decodes the response body for a 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/processes/myapp/start", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name":"myapp","status":"up"}))
      end)

      assert {:ok, 200, %{"name" => "myapp", "status" => "up"}} =
               Client.post("/processes/myapp/start")
    end

    test "decodes a 422 error body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/processes/myapp/stop", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(422, ~s({"name":"myapp","error":"not_running"}))
      end)

      assert {:ok, 422, %{"error" => "not_running"}} =
               Client.post("/processes/myapp/stop")
    end
  end

  describe "transport_message/1" do
    test "maps :nxdomain to the canonical not-running message" do
      assert Client.transport_message(:nxdomain) ==
               "Bates is not running. Start it with: batesd"
    end

    test "maps {:failed_connect, _} to the canonical not-running message" do
      reason = {:failed_connect, [{:to_address, {~c"bates.test", 443}}]}

      assert Client.transport_message(reason) ==
               "Bates is not running. Start it with: batesd"
    end

    test "falls through for unrecognized errors" do
      assert Client.transport_message(:timeout) ==
               "bates: request failed: :timeout"
    end
  end
end
