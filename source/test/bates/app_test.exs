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

  test "service with `port: :auto` and no hostname is assigned a port" do
    config =
      {"testapp", ".",
       [
         %Service{
           name: "worker",
           command: "elixir test/support/test_server.ex",
           port: :auto,
           hostname: nil,
           middleware: ["port"]
         }
       ]}

    start_supervised!({App, config})
    :ok = App.up("testapp")

    assert_eventually(fn -> App.status("testapp") == "up" end)

    [service] = App.services("testapp")
    assert is_integer(service.port)
    assert service.port > 0
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

  describe "environment exports" do
    alias Bates.TestSupport.{
      EnvironmentOverride,
      EnvironmentRecorder,
      ExportProducer
    }

    setup do
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:producer")
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:middle")
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:consumer")

      Bates.Middleware.Registry.register("export_producer", ExportProducer)

      Bates.Middleware.Registry.register(
        "environment_recorder",
        EnvironmentRecorder
      )

      Bates.Middleware.Registry.register(
        "environment_override",
        EnvironmentOverride
      )

      on_exit(fn ->
        Bates.Middleware.Registry.unregister("export_producer")
        Bates.Middleware.Registry.unregister("environment_recorder")
        Bates.Middleware.Registry.unregister("environment_override")
        Application.delete_env(:bates, :export_producer_exports)
        Application.delete_env(:bates, :environment_recorder)
        Application.delete_env(:bates, :environment_override)
      end)

      :ok
    end

    # Producers must boot a TCP listener so the readiness check can fire
    # `start_eligible/1` for downstream consumers. `test_server.ex` boots
    # on `$PORT`; the `port` middleware sets that env var.
    defp producer(name, opts \\ []) do
      depends_on = Keyword.get(opts, :depends_on, [])

      command =
        Keyword.get(opts, :command, "elixir test/support/test_server.ex")

      %Service{
        name: name,
        command: command,
        port: nil,
        hostname: "#{name}.testapp.test",
        middleware: ["port", "export_producer"],
        depends_on: depends_on
      }
    end

    defp consumer(name, opts) do
      depends_on = Keyword.fetch!(opts, :depends_on)

      middleware =
        Keyword.get(opts, :middleware, ["port", "environment_recorder"])

      %Service{
        name: name,
        command: "elixir test/support/test_server.ex",
        port: nil,
        hostname: "#{name}.testapp.test",
        middleware: middleware,
        depends_on: depends_on
      }
    end

    # `:sys.get_state/1` reaches into the App GenServer because there's no
    # public API for reading per-service `exports`. Replace if one is added.
    defp service_state(app_name, service_name) do
      pid =
        GenServer.whereis({:via, Registry, {Bates.ProcessRegistry, app_name}})

      :sys.get_state(pid).services |> Map.fetch!(service_name)
    end

    defp recorded_env(service_name) do
      Application.get_env(:bates, :environment_recorder, %{})
      |> Map.get(service_name, %{})
    end

    test "consumer's seeded environment includes the direct dep's exports" do
      Application.put_env(:bates, :export_producer_exports, %{
        "producer" => %{"DATABASE_URL" => "postgres://localhost/db"}
      })

      config =
        {"testapp", ".",
         [
           producer("producer"),
           consumer("consumer", depends_on: ["producer"])
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      assert recorded_env("consumer")["DATABASE_URL"] ==
               "postgres://localhost/db"
    end

    test "transitive exports reach the deepest consumer" do
      Application.put_env(:bates, :export_producer_exports, %{
        "producer" => %{"FROM_PRODUCER" => "p"},
        "middle" => %{"FROM_MIDDLE" => "m"}
      })

      config =
        {"testapp", ".",
         [
           producer("producer"),
           producer("middle", depends_on: ["producer"]),
           consumer("consumer", depends_on: ["middle"])
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      env = recorded_env("consumer")
      assert env["FROM_PRODUCER"] == "p"
      assert env["FROM_MIDDLE"] == "m"
    end

    test "direct dep overrides transitive dep on same key" do
      Application.put_env(:bates, :export_producer_exports, %{
        "producer" => %{"SHARED" => "from-producer"},
        "middle" => %{"SHARED" => "from-middle"}
      })

      config =
        {"testapp", ".",
         [
           producer("producer"),
           producer("middle", depends_on: ["producer"]),
           consumer("consumer", depends_on: ["middle"])
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      assert recorded_env("consumer")["SHARED"] == "from-middle"
    end

    test "consumer middleware overrides the seeded value" do
      Application.put_env(:bates, :export_producer_exports, %{
        "producer" => %{"SHARED" => "from-producer"}
      })

      Application.put_env(:bates, :environment_override, %{
        "consumer" => %{"SHARED" => "from-consumer"}
      })

      config =
        {"testapp", ".",
         [
           producer("producer"),
           consumer(
             "consumer",
             depends_on: ["producer"],
             middleware: [
               "port",
               "environment_override",
               "environment_recorder"
             ]
           )
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      assert recorded_env("consumer")["SHARED"] == "from-consumer"
    end

    test "exports persist on the producer state while running" do
      Application.put_env(:bates, :export_producer_exports, %{
        "producer" => %{"DATABASE_URL" => "postgres://localhost/db"}
      })

      config = {"testapp", ".", [producer("producer")]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      assert service_state("testapp", "producer").exports == %{
               "DATABASE_URL" => "postgres://localhost/db"
             }
    end

    test "exports clear after down" do
      Application.put_env(:bates, :export_producer_exports, %{
        "producer" => %{"DATABASE_URL" => "postgres://localhost/db"}
      })

      config = {"testapp", ".", [producer("producer")]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)
      assert service_state("testapp", "producer").exports != %{}

      :ok = App.down("testapp")

      assert service_state("testapp", "producer").exports == %{}
    end

    test "exports clear after a crash" do
      Application.put_env(:bates, :export_producer_exports, %{
        "producer" => %{"DATABASE_URL" => "postgres://localhost/db"}
      })

      config =
        {"testapp", ".", [producer("producer", command: "exit 1")]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_receive {:status, "crashed", _details}, 5_000

      assert service_state("testapp", "producer").exports == %{}
    end

    test "consumer user-environment can reference a dependency's export" do
      Application.put_env(:bates, :export_producer_exports, %{
        "producer" => %{"DB_PORT" => "12345"}
      })

      env_file =
        Path.join(
          System.tmp_dir!(),
          "bates_dep_env_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(env_file) end)

      consumer = %Service{
        name: "consumer",
        command:
          ~s|sh -c 'echo "$DATABASE_URL" > #{env_file}; exec elixir test/support/test_server.ex'|,
        port: nil,
        hostname: "consumer.testapp.test",
        middleware: ["port"],
        depends_on: ["producer"],
        environment: %{
          "DATABASE_URL" => "postgres://localhost:$DB_PORT/foo"
        }
      }

      config = {"testapp", ".", [producer("producer"), consumer]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn ->
        services = App.services("testapp")
        Enum.any?(services, &(&1.name == "consumer" and &1.status == "up"))
      end)

      assert env_file |> File.read!() |> String.trim() ==
               "postgres://localhost:12345/foo"
    end
  end

  describe "exports_settled broadcast" do
    alias Bates.TestSupport.ExportProducer

    setup do
      Bates.Middleware.Registry.register("export_producer", ExportProducer)

      on_exit(fn ->
        Bates.Middleware.Registry.unregister("export_producer")
        Application.delete_env(:bates, :export_producer_exports)
      end)

      :ok
    end

    test "fires once with empty exports for a port-less service" do
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

      assert_receive {:exports_settled, %{}}, 5_000
    end

    test "fires with merged exports from a producer middleware" do
      Application.put_env(:bates, :export_producer_exports, %{
        "worker" => %{"FOO" => "bar"}
      })

      config =
        {"testapp", ".",
         [
           %Service{
             name: "worker",
             command: "sleep 999",
             port: nil,
             hostname: nil,
             middleware: ["export_producer"]
           }
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_receive {:exports_settled, %{"FOO" => "bar"}}, 5_000
    end

    test "merges exports across services with last-writer-wins by start order" do
      Application.put_env(:bates, :export_producer_exports, %{
        "first" => %{"SHARED" => "from-first", "ONLY_FIRST" => "1"},
        "second" => %{"SHARED" => "from-second", "ONLY_SECOND" => "2"}
      })

      config =
        {"testapp", ".",
         [
           %Service{
             name: "first",
             command: "sleep 999",
             port: nil,
             hostname: nil,
             middleware: ["export_producer"]
           },
           %Service{
             name: "second",
             command: "sleep 999",
             port: nil,
             hostname: nil,
             middleware: ["export_producer"]
           }
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_receive {:exports_settled, exports}, 5_000
      assert exports["ONLY_FIRST"] == "1"
      assert exports["ONLY_SECOND"] == "2"
      assert exports["SHARED"] == "from-second"
    end

    test "fires exactly once across multiple :up calls without :down" do
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
      assert_receive {:exports_settled, %{}}, 5_000

      :ok = App.up("testapp")
      refute_receive {:exports_settled, _}, 200
    end

    test "fires again after :down then :up" do
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
      assert_receive {:exports_settled, %{}}, 5_000

      :ok = App.down("testapp")
      :ok = App.up("testapp")
      assert_receive {:exports_settled, %{}}, 5_000
    end

    test "fires again after per-service :down then whole-app :up" do
      Application.put_env(:bates, :export_producer_exports, %{
        "producer" => %{"PGHOST" => "127.0.0.1"}
      })

      config =
        {"testapp", ".",
         [
           %Service{
             name: "producer",
             command: "elixir test/support/test_server.ex",
             port: nil,
             hostname: "producer.testapp.test",
             middleware: ["port", "export_producer"]
           },
           %Service{
             name: "consumer",
             command: "sleep 999",
             port: nil,
             hostname: nil,
             depends_on: ["producer"]
           }
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")
      assert_receive {:exports_settled, %{"PGHOST" => "127.0.0.1"}}, 10_000

      # Stop the leaf (consumer). Producer stays up; its exports must
      # still be discoverable when the next `:up` settles.
      {:ok, _} = App.down("testapp", "consumer")

      :ok = App.up("testapp")
      assert_receive {:exports_settled, %{"PGHOST" => "127.0.0.1"}}, 10_000
    end
  end

  describe "snapshot/1" do
    test "returns status, exports, and reason atomically" do
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

      snapshot = App.snapshot("testapp")
      assert snapshot.status == "down"
      assert snapshot.exports == %{}
      assert snapshot.reason == nil

      :ok = App.up("testapp")
      assert_receive {:exports_settled, _}, 5_000

      snapshot = App.snapshot("testapp")
      assert snapshot.status == "up"
      assert snapshot.exports == %{}
      assert snapshot.reason == nil
    end
  end

  describe "paused state" do
    test "starts not paused" do
      config = single_service_config()
      start_supervised!({App, config})
      refute App.paused?("testapp")
    end

    test "down/1 sets paused" do
      config = single_service_config()
      start_supervised!({App, config})
      :ok = App.down("testapp")
      assert App.paused?("testapp")
    end

    test "up/1 clears paused" do
      config = single_service_config()
      start_supervised!({App, config})
      :ok = App.down("testapp")
      assert App.paused?("testapp")
      :ok = App.up("testapp")
      refute App.paused?("testapp")
    end
  end

  describe "per-service down/up" do
    setup do
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:web")
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:vite")
      Phoenix.PubSub.subscribe(Bates.PubSub, "service:testapp:worker")
      :ok
    end

    defp chain_config do
      {"testapp", ".",
       [
         %Service{
           name: "vite",
           command: "elixir test/support/test_server.ex",
           port: nil,
           hostname: "vite.testapp.test",
           middleware: ["port"]
         },
         %Service{
           name: "web",
           command: "elixir test/support/test_server.ex",
           port: nil,
           hostname: "testapp.test",
           middleware: ["port"],
           depends_on: ["vite"]
         },
         %Service{
           name: "worker",
           command: "sleep 999",
           port: nil,
           hostname: nil,
           depends_on: ["web"]
         }
       ]}
    end

    test "down/2 of a dependency cascades through dependents in reverse-topo order" do
      config = chain_config()
      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      {:ok, cascaded} = App.down("testapp", "vite")

      assert App.service_status("testapp", "vite") == "down"
      assert App.service_status("testapp", "web") == "down"
      assert App.service_status("testapp", "worker") == "down"

      assert cascaded == [
               %{service: "worker", status: "down"},
               %{service: "web", status: "down"}
             ]
    end

    test "down/2 of a leaf only stops the leaf with empty cascade" do
      config = chain_config()
      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      {:ok, cascaded} = App.down("testapp", "worker")

      assert cascaded == []
      assert App.service_status("testapp", "worker") == "down"
      assert App.service_status("testapp", "web") == "up"
      assert App.service_status("testapp", "vite") == "up"
    end

    test "down/2 with already-stopped dependents returns empty cascade and sets paused" do
      config = chain_config()
      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      {:ok, _} = App.down("testapp", "worker")
      {:ok, _} = App.down("testapp", "web")

      {:ok, cascaded} = App.down("testapp", "vite")

      assert cascaded == []
      assert App.paused?("testapp")
    end

    test "down/2 sets paused" do
      config = chain_config()
      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      refute App.paused?("testapp")

      {:ok, _} = App.down("testapp", "worker")
      assert App.paused?("testapp")
    end

    test "up/2 transitively auto-starts dependencies" do
      config = chain_config()
      start_supervised!({App, config})

      :ok = App.up("testapp", "worker")

      # Vite is the deepest dep; it gets started first. Web won't enter
      # `starting` until vite is `up`.
      assert App.service_status("testapp", "vite") in ["starting", "up"]
      assert App.service_status("testapp", "web") == "down"

      assert_eventually(fn ->
        App.service_status("testapp", "vite") == "up"
      end)

      assert_eventually(fn ->
        App.service_status("testapp", "web") in ["starting", "up"]
      end)

      assert_eventually(fn ->
        App.service_status("testapp", "worker") == "up"
      end)
    end

    test "up/2 clears paused" do
      config = chain_config()
      start_supervised!({App, config})

      :ok = App.down("testapp")
      assert App.paused?("testapp")

      :ok = App.up("testapp", "worker")
      refute App.paused?("testapp")
    end

    test "up/2 of a dependency does not auto-start dependents" do
      config = chain_config()
      start_supervised!({App, config})

      :ok = App.up("testapp", "vite")

      assert_eventually(fn ->
        App.service_status("testapp", "vite") == "up"
      end)

      # vite has dependents (web, worker) but they were not requested.
      # Give the readiness cascade a chance to run, then verify they
      # stayed `down`.
      Process.sleep(200)

      assert App.service_status("testapp", "web") == "down"
      assert App.service_status("testapp", "worker") == "down"
    end

    test "up/2 of a mid-chain service starts its deps but not its dependents" do
      config = chain_config()
      start_supervised!({App, config})

      :ok = App.up("testapp", "web")

      assert_eventually(fn ->
        App.service_status("testapp", "web") == "up"
      end)

      assert App.service_status("testapp", "vite") == "up"

      # `worker` depends on `web`, but `worker` was not part of the
      # requested closure, so it must stay `down`.
      Process.sleep(200)

      assert App.service_status("testapp", "worker") == "down"
    end

    test "down/2 with unknown service returns error" do
      config = chain_config()
      start_supervised!({App, config})

      assert {:error, :unknown_service} =
               App.down("testapp", "does_not_exist")
    end

    test "up/2 with unknown service returns error" do
      config = chain_config()
      start_supervised!({App, config})

      assert {:error, :unknown_service} =
               App.up("testapp", "does_not_exist")
    end
  end

  describe "user environment" do
    test "substitutes $NAME against middleware-produced env values" do
      env_file =
        Path.join(
          System.tmp_dir!(),
          "bates_envsub_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(env_file) end)

      config =
        {"testapp", ".",
         [
           %Service{
             name: "web",
             command:
               ~s|sh -c 'echo "$VITE_RUBY_PORT" > #{env_file}; exec elixir test/support/test_server.ex'|,
             port: nil,
             hostname: "testapp.test",
             middleware: ["port"],
             environment: %{"VITE_RUBY_PORT" => "$PORT"}
           }
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      [service] = App.services("testapp")

      assert env_file |> File.read!() |> String.trim() ==
               Integer.to_string(service.port)
    end

    test "exposes a literal Service.environment value to the running service" do
      env_file =
        Path.join(
          System.tmp_dir!(),
          "bates_env_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(env_file) end)

      config =
        {"testapp", ".",
         [
           %Service{
             name: "web",
             command:
               ~s|sh -c 'echo "$RAILS_ENV" > #{env_file}; exec elixir test/support/test_server.ex'|,
             port: nil,
             hostname: "testapp.test",
             middleware: ["port"],
             environment: %{"RAILS_ENV" => "development"}
           }
         ]}

      start_supervised!({App, config})
      :ok = App.up("testapp")

      assert_eventually(fn -> App.status("testapp") == "up" end)

      assert env_file |> File.read!() |> String.trim() == "development"
    end
  end

  defp assert_eventually(fun, attempts \\ 50) do
    Bates.TestHelpers.assert_eventually(fun, attempts)
  end
end
