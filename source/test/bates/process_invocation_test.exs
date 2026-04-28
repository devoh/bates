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
  end
end
