defmodule Bates.CLI do
  @moduledoc false

  def main(argv) do
    case dispatch(argv) do
      :ok -> :ok
      code when is_integer(code) -> System.halt(code)
    end
  end

  @doc false
  def dispatch(["env" | rest]), do: Bates.CLI.Env.run(rest)
  def dispatch(_), do: usage()

  defp usage do
    IO.write(:stderr, "Usage: bates env <name>\n")
    2
  end
end
