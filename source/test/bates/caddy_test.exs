defmodule Bates.CaddyTest do
  use ExUnit.Case

  alias Bates.Caddy

  describe "generate_config/0" do
    test "produces valid JSON" do
      config = Caddy.generate_config()
      assert {:ok, decoded} = Jason.decode(config)
      assert is_map(decoded)
    end

    test "includes admin listener" do
      {:ok, config} = Jason.decode(Caddy.generate_config())
      assert config["admin"]["listen"] == "localhost:2019"
    end

    test "includes bates.test control route" do
      {:ok, config} = Jason.decode(Caddy.generate_config())
      routes = config["apps"]["http"]["servers"]["bates"]["routes"]

      control_route = Enum.find(routes, &(&1["@id"] == "route:bates.test"))
      assert control_route != nil
      assert [%{"host" => ["bates.test"]}] = control_route["match"]
    end

    test "includes catch-all *.test route" do
      {:ok, config} = Jason.decode(Caddy.generate_config())
      routes = config["apps"]["http"]["servers"]["bates"]["routes"]

      catch_all = Enum.find(routes, &(&1["@id"] == "route:catch-all"))
      assert catch_all != nil
      assert [%{"host" => ["*.test"]}] = catch_all["match"]
    end

    test "includes TLS internal automation" do
      {:ok, config} = Jason.decode(Caddy.generate_config())
      policies = config["apps"]["tls"]["automation"]["policies"]
      assert [%{"issuers" => [%{"module" => "internal"}]}] = policies
    end

    test "all routes have @id tags" do
      {:ok, config} = Jason.decode(Caddy.generate_config())
      routes = config["apps"]["http"]["servers"]["bates"]["routes"]

      for route <- routes do
        assert Map.has_key?(route, "@id"), "Route missing @id: #{inspect(route)}"
      end
    end

    test "all routes are terminal" do
      {:ok, config} = Jason.decode(Caddy.generate_config())
      routes = config["apps"]["http"]["servers"]["bates"]["routes"]

      for route <- routes do
        assert route["terminal"] == true, "Route not terminal: #{inspect(route["@id"])}"
      end
    end

    test "listens on ports 443 and 80" do
      {:ok, config} = Jason.decode(Caddy.generate_config())
      listen = config["apps"]["http"]["servers"]["bates"]["listen"]
      assert ":443" in listen
      assert ":80" in listen
    end
  end
end
