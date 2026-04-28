defmodule Bates.Middleware.AsdfTest do
  use ExUnit.Case, async: true

  alias Bates.ProcessInvocation
  alias Bates.Middleware.Asdf

  @source_line "source $(brew --prefix)/opt/asdf/libexec/asdf.sh"

  test "appends the asdf source line to an empty prologue" do
    invocation = %ProcessInvocation{command: "bin/rails server"}

    result = Asdf.apply(invocation, %{})

    assert result.prologue == [@source_line]
    assert result.command == "bin/rails server"
  end

  test "preserves existing prologue entries before the asdf line" do
    invocation = %ProcessInvocation{
      prologue: ["echo hello"],
      command: "bin/rails server"
    }

    result = Asdf.apply(invocation, %{})

    assert result.prologue == ["echo hello", @source_line]
  end
end
