defmodule Bates.ProcessInvocationTest do
  use ExUnit.Case, async: true

  alias Bates.ProcessInvocation

  describe "compile/1" do
    test "returns 'exec <command>' when prologue is empty" do
      invocation = %ProcessInvocation{command: "bin/rails server"}

      assert ProcessInvocation.compile(invocation) == "exec bin/rails server"
    end

    test "joins prologue commands with '; ' before exec'd command" do
      invocation = %ProcessInvocation{
        prologue: ["source asdf.sh", "echo starting"],
        command: "bin/rails server"
      }

      assert ProcessInvocation.compile(invocation) ==
               "source asdf.sh; echo starting; exec bin/rails server"
    end

    test "ignores exports when compiling" do
      invocation = %ProcessInvocation{
        command: "bin/rails server",
        exports: %{"DATABASE_URL" => "postgres://localhost/db"}
      }

      assert ProcessInvocation.compile(invocation) == "exec bin/rails server"
    end
  end

  describe "struct defaults" do
    test "exports defaults to an empty map" do
      invocation = %ProcessInvocation{command: "bin/rails server"}

      assert invocation.exports == %{}
    end

    test "custom exports survive struct construction" do
      invocation = %ProcessInvocation{
        command: "bin/rails server",
        exports: %{"DATABASE_URL" => "postgres://localhost/db"}
      }

      assert invocation.exports == %{"DATABASE_URL" => "postgres://localhost/db"}
    end
  end
end
