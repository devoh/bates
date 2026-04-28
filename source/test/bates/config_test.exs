defmodule Bates.ConfigTest do
  use ExUnit.Case

  alias Bates.Config

  test "parses single-service shorthand" do
    [{name, root, services}] = Config.applications("test/fixtures/config.toml")

    assert name == "testapp"
    assert root == "."
    assert length(services) == 1

    [service] = services
    assert service.name == "testapp"
    assert service.command == "elixir test/support/test_server.ex"
    assert service.hostname == "testapp.test"
    assert service.port == nil
  end

  test "parses multi-service config with hostnames and ports" do
    [{name, root, services}] = Config.applications("test/fixtures/multi_service_config.toml")

    assert name == "myapp"
    assert root == "/tmp/myapp"
    assert length(services) == 3

    service_map = Map.new(services, &{&1.name, &1})

    web = service_map["web"]
    assert web.command == "bin/rails server -p $PORT"
    assert web.hostname == "myapp.test"
    assert web.port == nil

    vite = service_map["vite"]
    assert vite.command == "bin/vite dev --port $PORT"
    assert vite.hostname == "vite.myapp.test"
    assert vite.port == nil

    worker = service_map["worker"]
    assert worker.command == "bin/sidekiq"
    assert worker.hostname == nil
    assert worker.port == nil
  end

  test "hostname true resolves to app name" do
    [{_name, _root, services}] = Config.applications("test/fixtures/multi_service_config.toml")
    web = Enum.find(services, &(&1.name == "web"))

    assert web.hostname == "myapp.test"
  end

  test "hostname string resolves to custom value" do
    [{_name, _root, services}] = Config.applications("test/fixtures/multi_service_config.toml")
    vite = Enum.find(services, &(&1.name == "vite"))

    assert vite.hostname == "vite.myapp.test"
  end

  test "portless service has nil port and nil hostname" do
    [{_name, _root, services}] = Config.applications("test/fixtures/multi_service_config.toml")
    worker = Enum.find(services, &(&1.name == "worker"))

    assert worker.port == nil
    assert worker.hostname == nil
  end

  test "returns empty list for missing config file" do
    assert Config.applications("nonexistent.toml") == []
  end

  describe "middleware" do
    test "auto-appends 'port' for routable services in single-service shorthand" do
      [{_name, _root, [service]}] = Config.applications("test/fixtures/config.toml")

      assert service.middleware == ["port"]
    end

    test "does not auto-append 'port' for portless services" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/multi_service_config.toml")

      worker = Enum.find(services, &(&1.name == "worker"))

      assert worker.middleware == []
    end

    test "auto-appends 'port' for routable services in multi-service config" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/multi_service_config.toml")

      web = Enum.find(services, &(&1.name == "web"))

      assert web.middleware == ["port"]
    end

    test "prepends app-level middleware to each service's list" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/middleware_config.toml")

      service_map = Map.new(services, &{&1.name, &1})

      assert service_map["web"].middleware == ["asdf", "port"]
      assert service_map["worker"].middleware == ["asdf"]
    end

    test "appends service-level middleware after app-level middleware" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/middleware_config.toml")

      vite = Enum.find(services, &(&1.name == "vite"))

      assert vite.middleware == ["asdf", "port"]
    end

    test "does not duplicate 'port' when user already listed it" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/middleware_config.toml")

      vite = Enum.find(services, &(&1.name == "vite"))

      assert Enum.count(vite.middleware, &(&1 == "port")) == 1
    end

    test "single-service shorthand picks up app-level middleware" do
      [{_name, _root, [service]}] =
        Config.applications("test/fixtures/single_service_middleware_config.toml")

      assert service.middleware == ["asdf", "port"]
    end

    test "returns {:error, {:unknown_middleware, name}} for unknown middleware" do
      assert Config.applications("test/fixtures/unknown_middleware_config.toml") ==
               {:error, {:unknown_middleware, "nope"}}
    end
  end
end
