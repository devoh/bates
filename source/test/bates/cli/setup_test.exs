defmodule Bates.CLI.SetupTest do
  use ExUnit.Case, async: true

  # The `sudo tee /etc/resolver/test` and `caddy trust` shell-outs are
  # not unit-tested. They're hand-tested per the plan's verification
  # steps. The pure helper `evaluate_resolver/1` covers the decision
  # logic that drives those shell-outs.

  alias Bates.CLI.Setup

  describe "evaluate_resolver/1" do
    test "creates when file is missing" do
      assert Setup.evaluate_resolver(:missing) == {:create, :missing}
    end

    test "ok when content exactly matches" do
      assert Setup.evaluate_resolver("nameserver 127.0.0.1") == :ok
    end

    test "ok when content matches with trailing whitespace" do
      assert Setup.evaluate_resolver("nameserver 127.0.0.1\n") == :ok
    end

    test "ok when content matches with leading whitespace" do
      assert Setup.evaluate_resolver("  nameserver 127.0.0.1  \n") == :ok
    end

    test "drift when file has additional options" do
      contents = "nameserver 127.0.0.1\nport 53"
      assert {:error, {:drift, ^contents}} = Setup.evaluate_resolver(contents)
    end

    test "drift when nameserver IP differs" do
      assert {:error, {:drift, "nameserver 192.168.1.1"}} =
               Setup.evaluate_resolver("nameserver 192.168.1.1")
    end

    test "drift when content has extra nameservers" do
      contents = "nameserver 127.0.0.1\nnameserver 8.8.8.8"
      assert {:error, {:drift, ^contents}} = Setup.evaluate_resolver(contents)
    end

    test "drift on a comment line" do
      assert {:error, {:drift, "# placeholder"}} =
               Setup.evaluate_resolver("# placeholder")
    end
  end
end
