defmodule Bates.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "no arguments writes usage to stderr and returns exit code 2" do
    {output, exit_code} = run_dispatch([])

    assert exit_code == 2
    assert output =~ "Usage: bates env <name>"
  end

  test "unknown subcommand writes usage to stderr and returns exit code 2" do
    {output, exit_code} = run_dispatch(["bogus"])

    assert exit_code == 2
    assert output =~ "Usage: bates env <name>"
  end

  test "`env` with no arguments writes usage and returns exit code 2" do
    {output, exit_code} = run_dispatch(["env"])

    assert exit_code == 2
    assert output =~ "Usage: bates env <name>"
  end

  defp run_dispatch(argv) do
    parent = self()

    output =
      capture_io(:stderr, fn ->
        result = Bates.CLI.dispatch(argv)
        send(parent, {:exit_code, result})
      end)

    receive do
      {:exit_code, code} -> {output, code}
    after
      0 -> {output, nil}
    end
  end
end
