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
end
