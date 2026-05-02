defmodule Bates.CLI.StartTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bates.CLI.Start

  # The successful boot path (`Application.ensure_all_started(:bates)`)
  # is not unit-tested here because the `:bates` application is already
  # started by ExUnit. It's verified by the manual smoke test.

  describe "argument parsing" do
    test "rejects unknown switches with usage and exit code 2" do
      stderr =
        capture_io(:stderr, fn ->
          assert Start.run(["--bogus"]) == 2
        end)

      assert stderr =~ "unknown option"
      assert stderr =~ "Usage: bates start"
    end

    test "rejects positional arguments with usage and exit code 2" do
      stderr =
        capture_io(:stderr, fn ->
          assert Start.run(["extra"]) == 2
        end)

      assert stderr =~ "unexpected argument"
      assert stderr =~ "Usage: bates start"
    end
  end

  describe "prerequisite gating" do
    test "exits 2 with a setup pointer when caddy is missing" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "")

      try do
        stderr =
          capture_io(:stderr, fn ->
            assert Start.run([]) == 2
          end)

        assert stderr =~ "prerequisite not met"
        assert stderr =~ "`caddy` not found"
        assert stderr =~ "Run `bates setup`"
      after
        if original_path do
          System.put_env("PATH", original_path)
        else
          System.delete_env("PATH")
        end
      end
    end
  end
end
