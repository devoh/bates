defmodule Bates.CLI do
  @moduledoc false

  def main(argv) do
    case dispatch(argv) do
      :ok -> :ok
      code when is_integer(code) -> System.halt(code)
    end
  end

  @doc false
  def dispatch(["setup"]), do: Bates.CLI.Setup.run()
  def dispatch(["status"]), do: Bates.CLI.Status.run()

  def dispatch(["up"]), do: Bates.CLI.Up.run()
  def dispatch(["up", name]) when is_binary(name), do: Bates.CLI.Up.run(name)

  def dispatch(["down"]), do: Bates.CLI.Down.run()

  def dispatch(["down", name]) when is_binary(name),
    do: Bates.CLI.Down.run(name)

  def dispatch(["restart"]), do: Bates.CLI.Restart.run()

  def dispatch(["restart", name]) when is_binary(name),
    do: Bates.CLI.Restart.run(name)

  def dispatch(["env"]), do: Bates.CLI.Env.run()
  def dispatch(["env", name]) when is_binary(name), do: Bates.CLI.Env.run(name)
  def dispatch(_), do: usage()

  defp usage do
    IO.write(:stderr, """
    Usage:
      bates setup
      bates status
      bates up [<name>]
      bates down [<name>]
      bates restart [<name>]
      bates env [<name>]

    When <name> is omitted, the application is resolved from the
    current working directory using each application's configured root.
    """)

    2
  end
end
