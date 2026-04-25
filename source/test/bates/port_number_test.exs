defmodule Bates.PortNumberTest do
  use ExUnit.Case, async: true

  test "returns a valid port number" do
    port = Bates.PortNumber.next()
    assert is_integer(port)
    assert port > 0
  end

  test "returns unique ports" do
    ports = for _ <- 1..3, do: Bates.PortNumber.next()
    assert length(Enum.uniq(ports)) == 3
  end
end
