defmodule ConjureTest do
  use ExUnit.Case
  doctest Conjure

  test "greets the world" do
    assert Conjure.hello() == :world
  end
end
