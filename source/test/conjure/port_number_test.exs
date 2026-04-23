defmodule Conjure.PortNumberTest do
  use ExUnit.Case, async: true

  setup do
    daemon = start_supervised!(Conjure.PortNumber)
    %{daemon: daemon}
  end

  test "next port", %{daemon: daemon} do
    assert Conjure.PortNumber.next(daemon) == 4200
    assert Conjure.PortNumber.next(daemon) == 4201
    assert Conjure.PortNumber.next(daemon) == 4202
  end
end
