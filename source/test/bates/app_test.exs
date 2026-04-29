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

    {"testapp", ".",
     [
       %Service{
         name: "testapp",
         command: command,
         port: port,
         hostname: "testapp.test",
         middleware: ["port"]
       }
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
    config =
      single_service_config(command: "elixir test/support/test_server.ex")

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
    config =
      single_service_config(command: "elixir test/support/test_server.ex")

    start_supervised!({App, config})
    :ok = App.up("testapp")

    assert_receive {:status, "starting"}, 1_000
    assert_receive {:status, "up"}, 10_000
  end

  test "portless service goes to up immediately" do
    Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:worker")

    config =
      {"testapp", ".",
       [
         %Service{
           name: "worker",
           command: "sleep 999",
           port: nil,
           hostname: nil
         }
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
    config =
      single_service_config(command: "elixir test/support/test_server.ex")

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
      {"testapp", ".",
       [
         %Service{
           name: "web",
           command: "elixir test/support/test_server.ex",
           port: nil,
           hostname: "testapp.test",
           middleware: ["port"]
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

  describe "depends_on" do
    setup do
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:web")
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:vite")
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:worker")
      :ok
    end

    defp multi_service_with_deps_config(opts \\ []) do
      vite_command =
        Keyword.get(opts, :vite_command, "elixir test/support/test_server.ex")

      web_command =
        Keyword.get(opts, :web_command, "elixir test/support/test_server.ex")

      {"testapp", ".",
       [
         %Service{
           name: "vite",
           command: vite_command,
           port: nil,
           hostname: "vite.testapp.test",
           middleware: ["port"]
         },
         %Service{
           name: "web",
           command: web_command,
           port: nil,
           hostname: "testapp.test",
           middleware: ["port"],
           depends_on: ["vite"]
         }
       ]}
    end

    test "dependent stays down while dependency is starting" do
      config = multi_service_with_deps_config(vite_command: "sleep 999")
      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert App.service_status("testapp", "vite") == "starting"
      assert App.service_status("testapp", "web") == "down"
    end

    test "dependent transitions to starting once dependency reaches up" do
      config = multi_service_with_deps_config()
      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_receive {:status, "up"}, 10_000

      assert_eventually(fn ->
        App.service_status("testapp", "web") in ["starting", "up"]
      end)

      assert_eventually(fn -> App.status("testapp") == "up" end)
    end

    test "dependent stays down when dependency crashes" do
      config = multi_service_with_deps_config(vite_command: "sleep 999")
      start_supervised!({App, config})
      :ok = App.up("testapp")

      # Test config sets readiness_timeout to 2_000ms, so vite times out.
      assert_receive {:status, "crashed", _details}, 5_000

      assert App.service_status("testapp", "vite") == "crashed"
      assert App.service_status("testapp", "web") == "down"
      assert App.status("testapp") == "crashed"
    end

    test "queued dependent does not start the readiness timer" do
      config = multi_service_with_deps_config(vite_command: "sleep 999")
      start_supervised!({App, config})
      :ok = App.up("testapp")

      # Wait for the parent's readiness timeout to fire.
      assert_receive {:status, "crashed", _details}, 5_000

      # The dependent never got `started_at` set, so its services entry has
      # no pid and reads as "down" rather than "crashed".
      assert App.service_status("testapp", "web") == "down"

      web_service = App.services("testapp") |> Enum.find(&(&1.name == "web"))
      assert web_service.port == nil
    end

    test "repeated :up restarts a crashed dependency" do
      config = multi_service_with_deps_config(vite_command: "sleep 999")
      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_receive {:status, "crashed", _details}, 5_000
      assert App.service_status("testapp", "vite") == "crashed"
      assert App.service_status("testapp", "web") == "down"

      :ok = App.up("testapp")

      # Re-running :up on a crashed service kicks off another start attempt
      # since pid == nil. Vite is "starting" again briefly.
      assert App.service_status("testapp", "vite") in ["starting", "crashed"]
    end

    test "self-up idempotency: repeated :up does not double-start" do
      config = multi_service_with_deps_config()
      start_supervised!({App, config})

      :ok = App.up("testapp")

      vite_state_first =
        App.services("testapp") |> Enum.find(&(&1.name == "vite"))

      :ok = App.up("testapp")

      vite_state_second =
        App.services("testapp") |> Enum.find(&(&1.name == "vite"))

      # Same assigned port means the service was not torn down and restarted.
      assert vite_state_first.port == vite_state_second.port
    end

    test "stops services in reverse topological order" do
      config = multi_service_with_deps_config()
      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      # Use a per-test agent to record stop-broadcast order. Subscribe a
      # dedicated process to each service's topic so we can attribute the
      # `{:status, "down"}` broadcasts to specific services.
      test = self()

      web_listener =
        spawn_link(fn ->
          Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:web")
          relay_down(test, "web")
        end)

      vite_listener =
        spawn_link(fn ->
          Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:vite")
          relay_down(test, "vite")
        end)

      # Give the subscribers a moment to register.
      Process.sleep(50)

      :ok = App.down("testapp")

      # Web (the dependent) must reach "down" before vite (the dependency).
      assert_receive {:service_down, first}, 5_000
      assert_receive {:service_down, second}, 5_000
      assert {first, second} == {"web", "vite"}

      Process.exit(web_listener, :kill)
      Process.exit(vite_listener, :kill)

      assert App.service_status("testapp", "vite") == "down"
      assert App.service_status("testapp", "web") == "down"
    end

    defp relay_down(test, name) do
      receive do
        {:status, "down"} -> send(test, {:service_down, name})
        _ -> relay_down(test, name)
      end
    end
  end

  describe "middleware" do
    defmodule MarkerMiddleware do
      @behaviour Bates.Middleware

      @impl true
      def apply(invocation, %{service: %{name: name}}) do
        marker_path =
          Application.fetch_env!(:bates, :marker_paths) |> Map.fetch!(name)

        %{
          invocation
          | prologue: invocation.prologue ++ ["touch #{marker_path}"]
        }
      end
    end

    setup do
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:web")
      :ok
    end

    test "the port middleware exposes the assigned PORT to the running service" do
      port_file =
        Path.join(
          System.tmp_dir!(),
          "bates_port_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(port_file) end)

      config =
        {"testapp", ".",
         [
           %Service{
             name: "web",
             command:
               ~s|sh -c 'echo $PORT > #{port_file}; exec elixir test/support/test_server.ex'|,
             port: nil,
             hostname: "testapp.test",
             middleware: ["port"]
           }
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      [service] = App.services("testapp")

      {written_port, ""} =
        port_file |> File.read!() |> String.trim() |> Integer.parse()

      assert written_port == service.port
    end

    test "raises if a routable service is missing the port middleware" do
      Process.flag(:trap_exit, true)

      config =
        {"testapp", ".",
         [
           %Service{
             name: "web",
             command: "sleep 999",
             port: nil,
             hostname: "testapp.test",
             middleware: []
           }
         ]}

      pid = start_supervised!({App, config})
      ref = Process.monitor(pid)

      catch_exit(App.up("testapp"))

      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
      assert {%RuntimeError{message: message}, _stack} = reason
      assert message =~ ~s|"port" middleware|
    end

    test "a prologue command emitted by middleware runs before the service" do
      marker_path =
        Path.join(
          System.tmp_dir!(),
          "bates_marker_#{System.unique_integer([:positive])}"
        )

      File.rm(marker_path)
      on_exit(fn -> File.rm(marker_path) end)

      Bates.Middleware.Registry.register("marker", MarkerMiddleware)
      Application.put_env(:bates, :marker_paths, %{"web" => marker_path})

      on_exit(fn ->
        Bates.Middleware.Registry.unregister("marker")
        Application.delete_env(:bates, :marker_paths)
      end)

      config =
        {"testapp", ".",
         [
           %Service{
             name: "web",
             command: "elixir test/support/test_server.ex",
             port: nil,
             hostname: "testapp.test",
             middleware: ["marker", "port"]
           }
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)
      assert File.exists?(marker_path)
    end
  end

  defp assert_eventually(fun, attempts \\ 50) do
    Bates.TestHelpers.assert_eventually(fun, attempts)
  end
end
