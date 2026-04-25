defmodule Conjure.TestHelpers do
  def assert_eventually(fun, attempts \\ 50) do
    if fun.() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(100)
        assert_eventually(fun, attempts - 1)
      else
        ExUnit.Assertions.flunk("Condition not met after waiting")
      end
    end
  end
end
