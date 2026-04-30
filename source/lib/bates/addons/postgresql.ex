defmodule Bates.Addons.Postgresql do
  @behaviour Bates.Addon
  @behaviour Bates.Middleware

  alias Bates.ProcessInvocation

  @command "postgres -D $PGDATA -p $PORT -k $PGDATA"
  @middleware ["port", "postgresql"]
  @data_subdir ".bates/postgresql"

  @impl Bates.Addon
  def definition, do: %{command: @command, middleware: @middleware}

  @impl Bates.Middleware
  def apply(%ProcessInvocation{} = invocation, %{
        root: root,
        assigned_port: port
      })
      when is_integer(port) do
    pgdata = Path.join(Path.expand(root), @data_subdir)

    invocation
    |> add_prologue()
    |> put_environment(pgdata, port)
    |> add_exports(port)
  end

  defp add_prologue(%ProcessInvocation{prologue: prologue} = invocation) do
    lines = [
      "mkdir -p \"$PGDATA\"",
      "[ -f \"$PGDATA/PG_VERSION\" ] || initdb -A trust -D \"$PGDATA\"",
      "if [ -f \"$PGDATA/postmaster.pid\" ]; then " <>
        "kill -0 $(head -1 \"$PGDATA/postmaster.pid\") 2>/dev/null || " <>
        "rm \"$PGDATA/postmaster.pid\"; fi"
    ]

    %{invocation | prologue: prologue ++ lines}
  end

  defp put_environment(%ProcessInvocation{} = invocation, pgdata, port) do
    environment =
      invocation.environment
      |> Map.put("PGDATA", pgdata)
      |> Map.put("PGHOST", "127.0.0.1")
      |> Map.put("PGPORT", to_string(port))

    %{invocation | environment: environment}
  end

  defp add_exports(%ProcessInvocation{} = invocation, port) do
    exports =
      invocation.exports
      |> Map.put("PGHOST", "127.0.0.1")
      |> Map.put("PGPORT", to_string(port))

    %{invocation | exports: exports}
  end
end
