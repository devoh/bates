defmodule Bates.Addons.PostgresqlIntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  import Bates.TestHelpers

  alias Bates.{App, Service}
  alias Bates.TestSupport.EnvironmentRecorder

  setup do
    root = make_temp_root()

    # `postgres` and `initdb` may be asdf shims that resolve via
    # `.tool-versions` in the CWD. The runtime CWD will be the temp
    # root, so resolve absolute paths from the test's CWD up front.
    postgres_path = resolve_binary!("postgres")
    initdb_path = resolve_binary!("initdb")

    # Pre-run `initdb` so the postgres process starts within the test's
    # 2 s `readiness_timeout`. The addon's prologue is a no-op when
    # `PG_VERSION` already exists; this exercises that branch.
    pgdata = Path.join(root, ".bates/postgresql")
    File.mkdir_p!(pgdata)
    {_output, 0} = System.cmd(initdb_path, ["-A", "trust", "-D", pgdata])

    Bates.Middleware.Registry.register(
      "environment_recorder",
      EnvironmentRecorder
    )

    on_exit(fn ->
      Bates.Middleware.Registry.unregister("environment_recorder")
      Application.delete_env(:bates, :environment_recorder)
      File.rm_rf!(root)
    end)

    {:ok, root: root, pgdata: pgdata, postgres_path: postgres_path}
  end

  test "boots a real postgres and propagates `PGHOST` / `PGPORT` to dependents",
       %{root: root, pgdata: pgdata, postgres_path: postgres_path} do
    Phoenix.PubSub.subscribe(Bates.PubSub, "service:integration:postgresql")
    Phoenix.PubSub.subscribe(Bates.PubSub, "service:integration:web")

    config =
      {"integration", root,
       [
         %Service{
           name: "postgresql",
           command: "#{postgres_path} -D $PGDATA -p $PORT -k $PGDATA",
           port: :auto,
           hostname: nil,
           middleware: ["port", "postgresql"],
           depends_on: []
         },
         %Service{
           name: "web",
           command: "sleep 999",
           port: nil,
           hostname: nil,
           middleware: ["environment_recorder"],
           depends_on: ["postgresql"]
         }
       ]}

    start_supervised!({App, config})
    :ok = App.up("integration")

    assert_eventually(
      fn -> App.service_status("integration", "postgresql") == "up" end,
      100
    )

    [postgres_service] =
      Enum.filter(App.services("integration"), &(&1.name == "postgresql"))

    assert is_integer(postgres_service.port)

    # Confirm postgres accepts TCP connections on the assigned port.
    assert {:ok, socket} =
             :gen_tcp.connect(~c"127.0.0.1", postgres_service.port, [], 1_000)

    :gen_tcp.close(socket)

    # `web`'s dependency on postgresql means it boots after postgres is up.
    assert_eventually(
      fn -> App.service_status("integration", "web") == "up" end,
      100
    )

    web_environment =
      Application.get_env(:bates, :environment_recorder, %{})
      |> Map.get("web", %{})

    assert web_environment["PGHOST"] == "127.0.0.1"
    assert web_environment["PGPORT"] == to_string(postgres_service.port)

    # Sanity-check the on-disk state.
    assert File.exists?(Path.join(pgdata, "PG_VERSION"))

    # Bring the app down so the postgres process exits before the
    # tempdir cleanup races with `postmaster.pid` removal.
    :ok = App.down("integration")
  end

  # macOS' default `System.tmp_dir!/0` lives under
  # `/var/folders/<...>/T`, which produces a Unix-domain socket path
  # that exceeds the 103-byte sun_path limit. `/tmp` is short enough.
  defp make_temp_root do
    suffix = System.unique_integer([:positive])
    path = Path.join("/tmp", "bates_pg_#{suffix}")
    File.mkdir_p!(path)
    path
  end

  # Resolve a binary to an absolute path under the test's CWD so the
  # postgres command works when exec switches to the temp root (where
  # asdf shims would otherwise fail to find a `.tool-versions`).
  defp resolve_binary!(name) do
    case System.cmd("asdf", ["which", name], stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      _ ->
        case System.find_executable(name) do
          nil -> flunk("#{name} not on PATH; required for integration test")
          path -> path
        end
    end
  end
end
