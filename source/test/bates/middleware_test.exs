defmodule Bates.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Bates.{Middleware, ProcessInvocation}
  alias Bates.Middleware.Registry

  describe "Registry.lookup/1" do
    test "returns the module for 'asdf'" do
      assert Registry.lookup("asdf") == {:ok, Bates.Middleware.Asdf}
    end

    test "returns the module for 'port'" do
      assert Registry.lookup("port") == {:ok, Bates.Middleware.Port}
    end

    test "returns :unknown for an unknown name" do
      assert Registry.lookup("nope") == {:error, :unknown}
    end
  end

  describe "Registry.lookup!/1" do
    test "returns the module for a known name" do
      assert Registry.lookup!("asdf") == Bates.Middleware.Asdf
    end

    test "raises for an unknown name" do
      assert_raise RuntimeError, ~r/Unknown middleware/, fn ->
        Registry.lookup!("nope")
      end
    end

    test "raised error lists the known middleware names" do
      error =
        assert_raise RuntimeError, fn ->
          Registry.lookup!("nope")
        end

      assert error.message =~ "asdf"
      assert error.message =~ "port"
    end
  end

  describe "apply_pipeline/3" do
    defmodule PrologueA do
      @behaviour Bates.Middleware
      @impl true
      def apply(invocation, _context) do
        %{invocation | prologue: invocation.prologue ++ ["A"]}
      end
    end

    defmodule PrologueB do
      @behaviour Bates.Middleware
      @impl true
      def apply(invocation, _context) do
        %{invocation | prologue: invocation.prologue ++ ["B"]}
      end
    end

    test "calls each module in order, threading the invocation through" do
      initial = %ProcessInvocation{command: "true"}

      result = Middleware.apply_pipeline(initial, [PrologueA, PrologueB], %{})

      assert result.prologue == ["A", "B"]
      assert result.command == "true"
    end

    test "returns the input unchanged when the module list is empty" do
      initial = %ProcessInvocation{command: "true"}

      assert Middleware.apply_pipeline(initial, [], %{}) == initial
    end
  end
end
