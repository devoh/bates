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
    [{name, root, services}] =
      Config.applications("test/fixtures/multi_service_config.toml")

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
    [{_name, _root, services}] =
      Config.applications("test/fixtures/multi_service_config.toml")

    web = Enum.find(services, &(&1.name == "web"))

    assert web.hostname == "myapp.test"
  end

  test "hostname string resolves to custom value" do
    [{_name, _root, services}] =
      Config.applications("test/fixtures/multi_service_config.toml")

    vite = Enum.find(services, &(&1.name == "vite"))

    assert vite.hostname == "vite.myapp.test"
  end

  test "portless service has nil port and nil hostname" do
    [{_name, _root, services}] =
      Config.applications("test/fixtures/multi_service_config.toml")

    worker = Enum.find(services, &(&1.name == "worker"))

    assert worker.port == nil
    assert worker.hostname == nil
  end

  test "returns empty list for missing config file" do
    assert Config.applications("nonexistent.toml") == []
  end

  describe "applications/0" do
    test "reads the configured `:config_path` from the application env" do
      Application.put_env(:bates, :config_path, "test/fixtures/config.toml")
      on_exit(fn -> Application.delete_env(:bates, :config_path) end)

      [{name, _root, _services}] = Config.applications()

      assert name == "testapp"
    end

    test "falls back to ~/.config/bates/config.toml when the env is unset" do
      Application.delete_env(:bates, :config_path)
      assert Config.path() =~ ".config/bates/config.toml"
    end
  end

  describe "port" do
    test "translates `port = \"auto\"` to `Service.port: :auto`" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/port_auto_config.toml")

      queue = Enum.find(services, &(&1.name == "queue"))

      assert queue.port == :auto
      assert queue.hostname == nil
    end

    test "returns {:error, {:invalid_port, app, service, value}} for a non-integer string" do
      assert Config.applications(
               "test/fixtures/invalid_port_value_config.toml"
             ) ==
               {:error, {:invalid_port, "myapp", "queue", "garbage"}}
    end
  end

  describe "middleware" do
    test "auto-appends 'port' and 'hostname' for routable services in single-service shorthand" do
      [{_name, _root, [service]}] =
        Config.applications("test/fixtures/config.toml")

      assert service.middleware == ["port", "hostname"]
    end

    test "does not auto-append 'port' for portless services" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/multi_service_config.toml")

      worker = Enum.find(services, &(&1.name == "worker"))

      assert worker.middleware == []
    end

    test "auto-appends 'port' and 'hostname' for routable services in multi-service config" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/multi_service_config.toml")

      web = Enum.find(services, &(&1.name == "web"))

      assert web.middleware == ["port", "hostname"]
    end

    test "prepends app-level middleware to each service's list" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/middleware_config.toml")

      service_map = Map.new(services, &{&1.name, &1})

      assert service_map["web"].middleware == ["asdf", "port", "hostname"]
      assert service_map["worker"].middleware == ["asdf"]
    end

    test "appends service-level middleware after app-level middleware" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/middleware_config.toml")

      vite = Enum.find(services, &(&1.name == "vite"))

      assert vite.middleware == ["asdf", "port", "hostname"]
    end

    test "does not duplicate 'port' when user already listed it" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/middleware_config.toml")

      vite = Enum.find(services, &(&1.name == "vite"))

      assert Enum.count(vite.middleware, &(&1 == "port")) == 1
    end

    test "single-service shorthand picks up app-level middleware" do
      [{_name, _root, [service]}] =
        Config.applications(
          "test/fixtures/single_service_middleware_config.toml"
        )

      assert service.middleware == ["asdf", "port", "hostname"]
    end

    test "returns {:error, {:unknown_middleware, name}} for unknown middleware" do
      assert Config.applications(
               "test/fixtures/unknown_middleware_config.toml"
             ) ==
               {:error, {:unknown_middleware, "nope"}}
    end
  end

  describe "depends_on" do
    test "parses depends_on as a list of sibling service names" do
      [{_name, _root, services}] =
        Config.applications(
          "test/fixtures/multi_service_with_deps_config.toml"
        )

      service_map = Map.new(services, &{&1.name, &1})

      assert service_map["web"].depends_on == ["vite"]
      assert service_map["worker"].depends_on == ["web"]
    end

    test "defaults to empty list when depends_on key is absent" do
      [{_name, _root, services}] =
        Config.applications(
          "test/fixtures/multi_service_with_deps_config.toml"
        )

      service_map = Map.new(services, &{&1.name, &1})

      assert service_map["vite"].depends_on == []
    end

    test "single-service shorthand has empty depends_on" do
      [{_name, _root, [service]}] =
        Config.applications("test/fixtures/config.toml")

      assert service.depends_on == []
    end

    test "returns {:error, {:unknown_dependency, app, service, missing}} for unknown name" do
      assert Config.applications(
               "test/fixtures/unknown_dependency_config.toml"
             ) ==
               {:error, {:unknown_dependency, "myapp", "web", "nonexistent"}}
    end

    test "returns {:error, {:dependency_cycle, app, cycle}} for two-service cycle" do
      assert {:error, {:dependency_cycle, "myapp", cycle}} =
               Config.applications(
                 "test/fixtures/cyclic_dependencies_config.toml"
               )

      assert MapSet.new(cycle) == MapSet.new(["web", "worker"])
      assert length(cycle) == 2
    end

    test "returns {:error, {:dependency_cycle, app, cycle}} for self-loop" do
      assert Config.applications(
               "test/fixtures/self_loop_dependency_config.toml"
             ) ==
               {:error, {:dependency_cycle, "myapp", ["web"]}}
    end
  end

  describe "addons" do
    defmodule StubSidekickAddon do
      @behaviour Bates.Addon
      @behaviour Bates.Middleware

      @impl Bates.Addon
      def definition, do: %{command: "bin/sidekick"}

      @impl Bates.Middleware
      def apply(invocation, _context), do: invocation
    end

    defmodule StubCompanionAddon do
      @behaviour Bates.Addon
      @behaviour Bates.Middleware

      @impl Bates.Addon
      def definition, do: %{command: "bin/companion"}

      @impl Bates.Middleware
      def apply(invocation, _context), do: invocation
    end

    defmodule StubCustomAddon do
      @behaviour Bates.Addon
      @behaviour Bates.Middleware

      @impl Bates.Addon
      def definition,
        do: %{command: "bin/custom", middleware: ["asdf", "sidekick"]}

      @impl Bates.Middleware
      def apply(invocation, _context), do: invocation
    end

    defmodule StubPortBearingAddon do
      @behaviour Bates.Addon
      @behaviour Bates.Middleware

      @impl Bates.Addon
      def definition,
        do: %{command: "bin/queue -p $PORT", middleware: ["port", "queue"]}

      @impl Bates.Middleware
      def apply(invocation, _context), do: invocation
    end

    setup do
      Bates.Addons.Registry.register("sidekick", StubSidekickAddon)
      on_exit(fn -> Bates.Addons.Registry.unregister("sidekick") end)
      :ok
    end

    test "expands a short-form addon into a service with the registry's command" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/addons_short_form_config.toml")

      sidekick = Enum.find(services, &(&1.name == "sidekick"))

      assert sidekick.command == "bin/sidekick"
      assert sidekick.port == nil
      assert sidekick.hostname == nil
      assert sidekick.depends_on == []
    end

    test "short and table forms produce identical service maps" do
      [{_, _, short_services}] =
        Config.applications("test/fixtures/addons_short_form_config.toml")

      [{_, _, table_services}] =
        Config.applications("test/fixtures/addons_table_form_config.toml")

      assert Enum.sort_by(short_services, & &1.name) ==
               Enum.sort_by(table_services, & &1.name)
    end

    test "appends an implicit depends_on edge to every non-addon service" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/addons_short_form_config.toml")

      service_map = Map.new(services, &{&1.name, &1})

      assert "sidekick" in service_map["web"].depends_on
      assert "sidekick" in service_map["worker"].depends_on
    end

    test "does not add an implicit edge between sibling addons" do
      Bates.Addons.Registry.register("companion", StubCompanionAddon)
      on_exit(fn -> Bates.Addons.Registry.unregister("companion") end)

      toml = """
      [myapp]
      root = "/tmp/myapp"
      addons = ["sidekick", "companion"]

      [myapp.services.web]
      command = "bin/rails server -p $PORT"
      hostname = true
      """

      path = Path.join(System.tmp_dir!(), "addons_siblings_config.toml")
      File.write!(path, toml)
      on_exit(fn -> File.rm(path) end)

      [{_name, _root, services}] = Config.applications(path)
      service_map = Map.new(services, &{&1.name, &1})

      assert service_map["sidekick"].depends_on == []
      assert service_map["companion"].depends_on == []
    end

    test "preserves user-declared depends_on alongside the appended addon edge" do
      [{_name, _root, services}] =
        Config.applications(
          "test/fixtures/addons_with_existing_depends_on_config.toml"
        )

      web = Enum.find(services, &(&1.name == "web"))

      assert web.depends_on == ["worker", "sidekick"]
    end

    test "expands single-service shorthand combined with addons" do
      [{_name, _root, services}] =
        Config.applications(
          "test/fixtures/addons_single_service_shorthand_config.toml"
        )

      service_map = Map.new(services, &{&1.name, &1})

      assert Map.has_key?(service_map, "testapp")
      assert Map.has_key?(service_map, "sidekick")
      assert "sidekick" in service_map["testapp"].depends_on
    end

    test "treats addons = [] as a no-op" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/addons_empty_list_config.toml")

      assert Enum.map(services, & &1.name) |> Enum.sort() == ["web", "worker"]

      Enum.each(services, fn service ->
        assert service.depends_on == []
      end)
    end

    test "concatenates app-level middleware with the addon definition's middleware" do
      [{_name, _root, services}] =
        Config.applications(
          "test/fixtures/addons_with_app_middleware_config.toml"
        )

      sidekick = Enum.find(services, &(&1.name == "sidekick"))

      assert sidekick.middleware == ["asdf", "sidekick"]
    end

    test "preserves an explicit middleware list from the addon definition" do
      Bates.Addons.Registry.register("custom", StubCustomAddon)
      on_exit(fn -> Bates.Addons.Registry.unregister("custom") end)

      toml = """
      [myapp]
      root = "/tmp/myapp"
      addons = ["custom"]

      [myapp.services.web]
      command = "bin/rails server -p $PORT"
      hostname = true
      """

      path = Path.join(System.tmp_dir!(), "addons_explicit_middleware.toml")
      File.write!(path, toml)
      on_exit(fn -> File.rm(path) end)

      [{_name, _root, services}] = Config.applications(path)
      custom = Enum.find(services, &(&1.name == "custom"))

      assert custom.middleware == ["asdf", "sidekick"]
    end

    test "returns {:error, {:unknown_addon, app, name}} for an unregistered addon" do
      assert Config.applications("test/fixtures/addons_unknown_config.toml") ==
               {:error, {:unknown_addon, "myapp", "nonexistent"}}
    end

    test "returns {:error, {:addon_name_collision, app, name}} when an addon collides with a service" do
      assert Config.applications("test/fixtures/addons_collision_config.toml") ==
               {:error, {:addon_name_collision, "myapp", "sidekick"}}
    end

    test "returns {:error, {:duplicate_addon, app, name}} for a repeated short-form name" do
      assert Config.applications("test/fixtures/addons_duplicate_config.toml") ==
               {:error, {:duplicate_addon, "myapp", "sidekick"}}
    end

    test "sets `port: :auto` for an addon whose middleware includes `port`" do
      Bates.Addons.Registry.register("queue", StubPortBearingAddon)
      on_exit(fn -> Bates.Addons.Registry.unregister("queue") end)

      toml = """
      [myapp]
      root = "/tmp/myapp"
      addons = ["queue"]

      [myapp.services.web]
      command = "bin/rails server -p $PORT"
      hostname = true
      """

      path = Path.join(System.tmp_dir!(), "addons_port_bearing_config.toml")
      File.write!(path, toml)
      on_exit(fn -> File.rm(path) end)

      [{_name, _root, services}] = Config.applications(path)
      queue = Enum.find(services, &(&1.name == "queue"))

      assert queue.port == :auto
    end

    test "leaves `port` as nil for an addon whose middleware omits `port`" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/addons_short_form_config.toml")

      sidekick = Enum.find(services, &(&1.name == "sidekick"))

      assert sidekick.port == nil
    end
  end

  describe "find_by_path/2" do
    setup do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "find_by_path_#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(path) end)
      {:ok, fixture_path: path}
    end

    defp write_config(path, contents) do
      File.write!(path, contents)
      path
    end

    test "returns the app when the cwd equals its root", %{fixture_path: path} do
      write_config(path, """
      [myapp]
      root = "/Users/me/Code/myapp"
      command = "bin/server"
      hostname = true
      """)

      assert {"myapp", "/Users/me/Code/myapp", _} =
               Config.find_by_path("/Users/me/Code/myapp", path)
    end

    test "returns the app when the cwd is nested under its root",
         %{fixture_path: path} do
      write_config(path, """
      [myapp]
      root = "/Users/me/Code/myapp"
      command = "bin/server"
      hostname = true
      """)

      assert {"myapp", _, _} =
               Config.find_by_path("/Users/me/Code/myapp/lib/foo", path)
    end

    test "picks the longest matching root when apps nest",
         %{fixture_path: path} do
      write_config(path, """
      [outer]
      root = "/Users/me/Code"
      command = "bin/outer"
      hostname = true

      [inner]
      root = "/Users/me/Code/myapp"
      command = "bin/inner"
      hostname = true
      """)

      assert {"inner", _, _} =
               Config.find_by_path("/Users/me/Code/myapp/sub", path)

      assert {"outer", _, _} =
               Config.find_by_path("/Users/me/Code/other", path)
    end

    test "returns nil when no app's root contains the path",
         %{fixture_path: path} do
      write_config(path, """
      [myapp]
      root = "/Users/me/Code/myapp"
      command = "bin/server"
      hostname = true
      """)

      assert Config.find_by_path("/tmp/elsewhere", path) == nil
    end

    test "does not match a sibling directory with a shared prefix",
         %{fixture_path: path} do
      write_config(path, """
      [myapp]
      root = "/Users/me/Code/foo"
      command = "bin/server"
      hostname = true
      """)

      assert Config.find_by_path("/Users/me/Code/foobar", path) == nil
    end

    test "expands `~` in the root before comparing", %{fixture_path: path} do
      write_config(path, """
      [myapp]
      root = "~/Code/myapp"
      command = "bin/server"
      hostname = true
      """)

      cwd = Path.expand("~/Code/myapp/lib")

      assert {"myapp", _, _} = Config.find_by_path(cwd, path)
    end
  end

  describe "environment" do
    test "parses an app-level [environment] table into each service" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/environment_config.toml")

      service_map = Map.new(services, &{&1.name, &1})

      assert service_map["worker"].environment == %{
               "RAILS_ENV" => "development",
               "LOG_LEVEL" => "debug"
             }
    end

    test "service-level entries override app-level on key conflict" do
      [{_name, _root, services}] =
        Config.applications("test/fixtures/environment_config.toml")

      web = Enum.find(services, &(&1.name == "web"))

      assert web.environment == %{
               "RAILS_ENV" => "test",
               "LOG_LEVEL" => "debug",
               "VITE_RUBY_PORT" => "$PORT"
             }
    end

    test "returns {:error, {:malformed_environment_value, ...}} for unclosed ${" do
      assert Config.applications(
               "test/fixtures/malformed_environment_config.toml"
             ) ==
               {:error,
                {:malformed_environment_value, "myapp", "myapp", "BROKEN"}}
    end

    test "returns {:error, {:invalid_environment_value, ...}} for a non-string value" do
      assert Config.applications(
               "test/fixtures/non_string_environment_config.toml"
             ) ==
               {:error,
                {:invalid_environment_value, "myapp", "myapp", "PORT_COUNT", 5}}
    end
  end
end
