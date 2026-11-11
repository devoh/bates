defmodule Bates.Middleware.AsdfTest do
  use ExUnit.Case, async: true

  alias Bates.ProcessInvocation
  alias Bates.Middleware.Asdf

  @shims_line ~S[export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"]

  test "appends the asdf shims line to an empty prologue" do
    invocation = %ProcessInvocation{command: "bin/rails server"}

    result = Asdf.apply(invocation, %{})

    assert result.prologue == [@shims_line]
    assert result.command == "bin/rails server"
  end

  test "preserves existing prologue entries before the asdf line" do
    invocation = %ProcessInvocation{
      prologue: ["echo hello"],
      command: "bin/rails server"
    }

    result = Asdf.apply(invocation, %{})

    assert result.prologue == ["echo hello", @shims_line]
  end
end
