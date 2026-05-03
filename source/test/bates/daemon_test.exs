defmodule Bates.DaemonTest do
  use ExUnit.Case, async: false

  alias Bates.Daemon

  describe "parse_argv/1" do
    test "with no args returns empty options" do
      assert {:ok, []} = Daemon.parse_argv([])
    end

    test "parses --config <path>" do
      assert {:ok, opts} = Daemon.parse_argv(["--config", "/tmp/foo.toml"])
      assert opts[:config] == "/tmp/foo.toml"
    end

    test "rejects unknown switches with a usage banner" do
      assert {:error, message} = Daemon.parse_argv(["--bogus"])
      assert message =~ "unknown option"
      assert message =~ "Usage: batesd [--config <path>]"
    end

    test "rejects unexpected positional arguments with a usage banner" do
      assert {:error, message} = Daemon.parse_argv(["extra"])
      assert message =~ "unexpected argument"
      assert message =~ "Usage: batesd [--config <path>]"
    end
  end

  describe "apply_options/1" do
    setup do
      original = Application.get_env(:bates, :config_path)

      on_exit(fn ->
        if original do
          Application.put_env(:bates, :config_path, original)
        else
          Application.delete_env(:bates, :config_path)
        end
      end)

      :ok
    end

    test "without :config leaves :bates, :config_path unset" do
      Application.delete_env(:bates, :config_path)
      assert :ok = Daemon.apply_options([])
      assert Application.get_env(:bates, :config_path) == nil
    end

    test "with :config expands and stores the path under :bates, :config_path" do
      assert :ok = Daemon.apply_options(config: "~/foo.toml")

      expected = Path.expand("~/foo.toml")
      assert Application.get_env(:bates, :config_path) == expected
    end
  end

  describe "apply_env/1" do
    setup do
      original = Application.get_env(:bates, :config_path)

      on_exit(fn ->
        if original do
          Application.put_env(:bates, :config_path, original)
        else
          Application.delete_env(:bates, :config_path)
        end
      end)

      :ok
    end

    test "without BATES_CONFIG_PATH leaves :bates, :config_path unchanged" do
      Application.put_env(:bates, :config_path, "/from/argv.toml")
      assert :ok = Daemon.apply_env(%{})
      assert Application.get_env(:bates, :config_path) == "/from/argv.toml"
    end

    test "with empty BATES_CONFIG_PATH leaves :bates, :config_path unchanged" do
      Application.put_env(:bates, :config_path, "/from/argv.toml")
      assert :ok = Daemon.apply_env(%{"BATES_CONFIG_PATH" => ""})
      assert Application.get_env(:bates, :config_path) == "/from/argv.toml"
    end

    test "with BATES_CONFIG_PATH expands and stores under :bates, :config_path" do
      assert :ok =
               Daemon.apply_env(%{"BATES_CONFIG_PATH" => "~/from-env.toml"})

      assert Application.get_env(:bates, :config_path) ==
               Path.expand("~/from-env.toml")
    end

    test "BATES_CONFIG_PATH overrides a previously argv-set config path" do
      Application.put_env(:bates, :config_path, "/from/argv.toml")
      assert :ok = Daemon.apply_env(%{"BATES_CONFIG_PATH" => "/from/env.toml"})
      assert Application.get_env(:bates, :config_path) == "/from/env.toml"
    end
  end

  describe "verify_prerequisites/0" do
    test "returns the formatted prereq diagnostic when caddy is missing" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "")

      try do
        assert {:error, message} = Daemon.verify_prerequisites()
        assert message =~ "prerequisite not met"
        assert message =~ "`caddy` not found"
        assert message =~ "Run `bates setup`"
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
