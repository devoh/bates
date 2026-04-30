defmodule Bates.Addon.RegistryTest do
  use ExUnit.Case, async: true

  alias Bates.Addon.Registry

  describe "lookup/1" do
    test "returns {:error, :unknown} for an unregistered name" do
      assert Registry.lookup("never-registered") == {:error, :unknown}
    end

    test "applies the default middleware list when registration omits it" do
      Registry.register("foo", %{command: "bar"})
      on_exit(fn -> Registry.unregister("foo") end)

      assert Registry.lookup("foo") ==
               {:ok, %{command: "bar", middleware: ["foo"]}}
    end

    test "preserves an explicit middleware list verbatim" do
      Registry.register("foo", %{
        command: "bar",
        middleware: ["asdf", "foo"]
      })

      on_exit(fn -> Registry.unregister("foo") end)

      assert Registry.lookup("foo") ==
               {:ok, %{command: "bar", middleware: ["asdf", "foo"]}}
    end
  end

  describe "lookup!/1" do
    test "returns the definition for a registered name" do
      Registry.register("foo", %{command: "bar"})
      on_exit(fn -> Registry.unregister("foo") end)

      assert Registry.lookup!("foo") ==
               %{command: "bar", middleware: ["foo"]}
    end

    test "raises with a helpful message for an unknown name" do
      assert_raise RuntimeError, ~r/Unknown addon/, fn ->
        Registry.lookup!("never-registered")
      end
    end

    test "raised error lists the known addon names" do
      Registry.register("alpha", %{command: "a"})
      Registry.register("beta", %{command: "b"})
      on_exit(fn -> Registry.unregister("alpha") end)
      on_exit(fn -> Registry.unregister("beta") end)

      error =
        assert_raise RuntimeError, fn ->
          Registry.lookup!("nope")
        end

      assert error.message =~ "alpha"
      assert error.message =~ "beta"
    end
  end

  describe "register/2 and unregister/1" do
    test "register/2 makes the addon discoverable" do
      Registry.register("stub", %{command: "echo stub"})
      on_exit(fn -> Registry.unregister("stub") end)

      assert {:ok, %{command: "echo stub"}} = Registry.lookup("stub")
    end

    test "unregister/1 removes a previously registered addon" do
      Registry.register("stub", %{command: "echo stub"})
      Registry.unregister("stub")

      assert Registry.lookup("stub") == {:error, :unknown}
    end

    test "unregister/1 is a no-op for an unregistered name" do
      assert Registry.unregister("never-registered") == :ok
    end
  end
end
