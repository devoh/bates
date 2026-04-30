defmodule Bates.Addons.RegistryTest do
  use ExUnit.Case, async: true

  alias Bates.Addons.Registry

  defmodule StubAddon do
    @behaviour Bates.Addon
    @behaviour Bates.Middleware

    @impl Bates.Addon
    def definition, do: %{command: "bar"}

    @impl Bates.Middleware
    def apply(invocation, _context), do: invocation
  end

  defmodule StubAddonWithMiddleware do
    @behaviour Bates.Addon
    @behaviour Bates.Middleware

    @impl Bates.Addon
    def definition, do: %{command: "bar", middleware: ["asdf", "foo"]}

    @impl Bates.Middleware
    def apply(invocation, _context), do: invocation
  end

  defmodule StubAddonAlpha do
    @behaviour Bates.Addon
    @behaviour Bates.Middleware

    @impl Bates.Addon
    def definition, do: %{command: "a"}

    @impl Bates.Middleware
    def apply(invocation, _context), do: invocation
  end

  defmodule StubAddonBeta do
    @behaviour Bates.Addon
    @behaviour Bates.Middleware

    @impl Bates.Addon
    def definition, do: %{command: "b"}

    @impl Bates.Middleware
    def apply(invocation, _context), do: invocation
  end

  describe "lookup/1" do
    test "returns {:error, :unknown} for an unregistered name" do
      assert Registry.lookup("never-registered") == {:error, :unknown}
    end

    test "applies the default middleware list when the definition omits it" do
      Registry.register("foo", StubAddon)
      on_exit(fn -> Registry.unregister("foo") end)

      assert Registry.lookup("foo") ==
               {:ok, %{command: "bar", middleware: ["foo"]}}
    end

    test "preserves an explicit middleware list verbatim" do
      Registry.register("foo", StubAddonWithMiddleware)
      on_exit(fn -> Registry.unregister("foo") end)

      assert Registry.lookup("foo") ==
               {:ok, %{command: "bar", middleware: ["asdf", "foo"]}}
    end
  end

  describe "lookup!/1" do
    test "returns the definition for a registered name" do
      Registry.register("foo", StubAddon)
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
      Registry.register("alpha", StubAddonAlpha)
      Registry.register("beta", StubAddonBeta)
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

  describe "lookup_module/1" do
    test "returns the registered module" do
      Registry.register("stub", StubAddon)
      on_exit(fn -> Registry.unregister("stub") end)

      assert Registry.lookup_module("stub") == {:ok, StubAddon}
    end

    test "returns {:error, :unknown} for an unregistered name" do
      assert Registry.lookup_module("never-registered") == {:error, :unknown}
    end
  end

  describe "register/2 and unregister/1" do
    test "register/2 makes the addon discoverable" do
      Registry.register("stub", StubAddon)
      on_exit(fn -> Registry.unregister("stub") end)

      assert {:ok, %{command: "bar"}} = Registry.lookup("stub")
    end

    test "register/2 makes the module resolvable via Bates.Middleware.Registry" do
      Registry.register("stub", StubAddon)
      on_exit(fn -> Registry.unregister("stub") end)

      assert Bates.Middleware.Registry.lookup("stub") == {:ok, StubAddon}
    end

    test "unregister/1 removes a previously registered addon" do
      Registry.register("stub", StubAddon)
      Registry.unregister("stub")

      assert Registry.lookup("stub") == {:error, :unknown}
    end

    test "unregister/1 is a no-op for an unregistered name" do
      assert Registry.unregister("never-registered") == :ok
    end
  end
end
