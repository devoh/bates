defmodule Bates.Addons.PostgresqlTest do
  use ExUnit.Case, async: true

  alias Bates.Addons.Postgresql
  alias Bates.ProcessInvocation

  describe "definition/0" do
    test "returns the postgres command and the port + postgresql middleware" do
      assert Postgresql.definition() == %{
               command: "postgres -D $PGDATA -p $PORT -k $PGDATA",
               middleware: ["port", "postgresql"]
             }
    end
  end

  describe "apply/2" do
    setup do
      invocation = %ProcessInvocation{
        command: "postgres -D $PGDATA -p $PORT -k $PGDATA"
      }

      context = %{root: "/tmp/myapp", assigned_port: 5_555}

      {:ok, invocation: invocation, context: context}
    end

    test "appends mkdir, conditional initdb, and stale-pid guard prologue lines",
         %{invocation: invocation, context: context} do
      result = Postgresql.apply(invocation, context)

      assert result.prologue == [
               "mkdir -p \"$PGDATA\"",
               "[ -f \"$PGDATA/PG_VERSION\" ] || initdb -A trust -D \"$PGDATA\"",
               "if [ -f \"$PGDATA/postmaster.pid\" ]; then " <>
                 "kill -0 $(head -1 \"$PGDATA/postmaster.pid\") 2>/dev/null || " <>
                 "rm \"$PGDATA/postmaster.pid\"; fi"
             ]
    end

    test "stale-pid guard uses `kill -0` to test whether the recorded PID is alive",
         %{invocation: invocation, context: context} do
      result = Postgresql.apply(invocation, context)
      [_mkdir, _initdb, guard] = result.prologue

      assert guard =~ "kill -0 $(head -1"
      assert guard =~ "rm \"$PGDATA/postmaster.pid\""
    end

    test "prologue references `$PGDATA` rather than interpolating the path so " <>
           "roots containing spaces or shell metacharacters work",
         %{invocation: invocation, context: context} do
      context = %{context | root: "/tmp/My App"}
      result = Postgresql.apply(invocation, context)

      refute Enum.any?(result.prologue, &String.contains?(&1, "/tmp/My App"))
      assert Enum.all?(result.prologue, &String.contains?(&1, "$PGDATA"))
    end

    test "sets PGDATA, PGHOST, and PGPORT in the environment",
         %{invocation: invocation, context: context} do
      result = Postgresql.apply(invocation, context)

      assert result.environment["PGDATA"] == "/tmp/myapp/.bates/postgresql"
      assert result.environment["PGHOST"] == "127.0.0.1"
      assert result.environment["PGPORT"] == "5555"
    end

    test "exports only PGHOST and PGPORT (not PGUSER, PGDATABASE, DATABASE_URL)",
         %{invocation: invocation, context: context} do
      result = Postgresql.apply(invocation, context)

      assert Map.keys(result.exports) |> Enum.sort() == ["PGHOST", "PGPORT"]
      assert result.exports["PGHOST"] == "127.0.0.1"
      assert result.exports["PGPORT"] == "5555"
    end

    test "expands a relative root before deriving PGDATA", %{
      invocation: invocation
    } do
      cwd = File.cwd!()
      context = %{root: ".", assigned_port: 5_555}
      result = Postgresql.apply(invocation, context)

      assert result.environment["PGDATA"] ==
               Path.join(cwd, ".bates/postgresql")
    end
  end

  describe "registry integration" do
    test "Bates.Addons.Registry resolves \"postgresql\" to the addon definition" do
      assert Bates.Addons.Registry.lookup("postgresql") ==
               {:ok,
                %{
                  command: "postgres -D $PGDATA -p $PORT -k $PGDATA",
                  middleware: ["port", "postgresql"]
                }}
    end

    test "Bates.Addons.Registry.lookup_module/1 returns the addon module" do
      assert Bates.Addons.Registry.lookup_module("postgresql") ==
               {:ok, Bates.Addons.Postgresql}
    end

    test "Bates.Middleware.Registry resolves \"postgresql\" via fall-through" do
      assert Bates.Middleware.Registry.lookup("postgresql") ==
               {:ok, Bates.Addons.Postgresql}
    end
  end
end
