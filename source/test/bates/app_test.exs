defmodule Bates.AppTest do
  use ExUnit.Case

  alias Bates.{App, Service}

  setup do
    Phoenix.PubSub.subscribe(Bates.PubSub, "app:testapp")
    Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:testapp")
    :ok
  end

  defp single_service_config(opts \\ []) do
    port = Keyword.get(opts, :port, nil)
    command = Keyword.get(opts, :command, "sleep 999")

    {"testapp", ".", [
      %Service{name: "testapp", command: command, port: port, hostname: "testapp.test"}
    ]}
  end

  test "status is 'starting' immediately after up/1" do
    config = single_service_config()
    start_supervised!({App, config})
    :ok = App.up("testapp")

    assert App.status("testapp") == "starting"
    assert_received {:status, "starting"}
  end

  test "transitions to 'up' when port is listening" do
    config = single_service_config(command: "elixir test/support/test_server.ex")
    start_supervised!({App, config})
    :ok = App.up("testapp")

    assert_received {:status, "starting"}
    assert_receive {:status, "up"}, 10_000

    assert App.status("testapp") == "up"
  end

  test "transitions to 'crashed' on readiness timeout" do
    config = single_service_config(command: "sleep 999")
    start_supervised!({App, config})
    :ok = App.up("testapp")

    assert_received {:status, "starting"}

    # Test config sets readiness_timeout to 2_000ms
    assert_receive {:status, "crashed", message}, 5_000
    assert message =~ "Timed out waiting for port"
    assert App.status("testapp") == "crashed"
  end

  test "down works while in 'starting' state" do
    config = single_service_config(command: "sleep 999")
    start_supervised!({App, config})
    :ok = App.up("testapp")

    assert App.status("testapp") == "starting"

    :ok = App.down("testapp")

    assert App.status("testapp") == "down"
  end

  test "PubSub broadcasts fire for each transition" do
    config = single_service_config(command: "elixir test/support/test_server.ex")
    start_supervised!({App, config})
    :ok = App.up("testapp")

    assert_receive {:status, "starting"}, 1_000
    assert_receive {:status, "up"}, 10_000
  end

  test "portless service goes to up immediately" do
    Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:worker")

    config = {"testapp", ".", [
      %Service{name: "worker", command: "sleep 999", port: nil, hostname: nil}
    ]}

    start_supervised!({App, config})
    :ok = App.up("testapp")

    assert App.status("testapp") == "up"
    assert App.service_status("testapp", "worker") == "up"
  end

  test "services/1 returns service list with nil port when stopped" do
    config = single_service_config()
    start_supervised!({App, config})

    [service] = App.services("testapp")
    assert service.name == "testapp"
    assert service.hostname == "testapp.test"
    assert service.status == "down"
    assert service.port == nil
  end

  test "services/1 returns assigned port when running" do
    config = single_service_config(command: "elixir test/support/test_server.ex")
    start_supervised!({App, config})
    :ok = App.up("testapp")

    assert_eventually(fn -> App.status("testapp") == "up" end)

    [service] = App.services("testapp")
    assert is_integer(service.port)

    :ok = App.down("testapp")

    [service] = App.services("testapp")
    assert service.port == nil
  end

  describe "multi-service" do
    setup do
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:web")
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:worker")
      :ok
    end

    defp multi_service_config do
      {"testapp", ".", [
        %Service{
          name: "web",
          command: "elixir test/support/test_server.ex",
          port: nil,
          hostname: "testapp.test"
        },
        %Service{
          name: "worker",
          command: "sleep 999",
          port: nil,
          hostname: nil
        }
      ]}
    end

    test "all services start concurrently on up/1" do
      config = multi_service_config()
      start_supervised!({App, config})
      :ok = App.up("testapp")

      # Worker (portless) should go up immediately
      assert App.service_status("testapp", "worker") == "up"
      # Web should be starting
      assert App.service_status("testapp", "web") in ["starting", "up"]

      # Wait for web to come up
      assert_eventually(fn -> App.status("testapp") == "up" end)
    end

    test "down/1 stops all services" do
      config = multi_service_config()
      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      :ok = App.down("testapp")
      assert App.status("testapp") == "down"
      assert App.service_status("testapp", "web") == "down"
      assert App.service_status("testapp", "worker") == "down"
    end

    test "services/1 returns all services with status" do
      config = multi_service_config()
      start_supervised!({App, config})

      services = App.services("testapp") |> Map.new(&{&1.name, &1})

      assert services["web"].hostname == "testapp.test"
      assert services["web"].status == "down"
      assert services["worker"].hostname == nil
      assert services["worker"].status == "down"
    end
  end

  defp assert_eventually(fun, attempts \\ 50) do
    Bates.TestHelpers.assert_eventually(fun, attempts)
  end
end
