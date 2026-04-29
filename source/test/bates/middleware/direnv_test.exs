defmodule Bates.Middleware.DirenvTest do
  use ExUnit.Case, async: true

  alias Bates.ProcessInvocation
  alias Bates.Middleware.Direnv

  @source_line ~S[eval "$(direnv export bash)"]

  test "appends the direnv eval line to an empty prologue" do
    invocation = %ProcessInvocation{command: "bin/rails server"}

    result = Direnv.apply(invocation, %{})

    assert result.prologue == [@source_line]
    assert result.command == "bin/rails server"
  end

  test "preserves existing prologue entries before the direnv line" do
    invocation = %ProcessInvocation{
      prologue: ["echo hello"],
      command: "bin/rails server"
    }

    result = Direnv.apply(invocation, %{})

    assert result.prologue == ["echo hello", @source_line]
  end
end
