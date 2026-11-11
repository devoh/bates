defmodule Bates.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Bates.Environment

  describe "apply/3" do
    test "substitutes ${NAME} the same as $NAME" do
      env = %{"PORT" => "4000"}
      user = %{"URL" => "http://localhost:${PORT}"}

      result = Environment.apply(env, user, "web")

      assert result["URL"] == "http://localhost:4000"
    end

    test "$$ produces a literal $" do
      result = Environment.apply(%{}, %{"PRICE" => "$$5.00"}, "web")

      assert result["PRICE"] == "$5.00"
    end

    test "does not override keys already present in env" do
      env = %{"PORT" => "4000"}
      user = %{"PORT" => "9999"}

      result = Environment.apply(env, user, "web")

      assert result["PORT"] == "4000"
    end

    test "falls back to the inherited environment for references" do
      env = %{"PORT" => "4000"}
      user = %{"BIN" => "$HOME/bin", "URL" => "http://localhost:$PORT"}
      inherited = %{"HOME" => "/Users/me", "PORT" => "1"}

      result = Environment.apply(env, user, "web", inherited)

      assert result["BIN"] == "/Users/me/bin"
      assert result["URL"] == "http://localhost:4000"
      refute Map.has_key?(result, "HOME")
    end

    test "raises when a reference cannot be resolved" do
      message =
        ~s|service "web" environment variable "URL" references unknown variable "MISSING"|

      assert_raise ArgumentError, message, fn ->
        Environment.apply(%{}, %{"URL" => "http://$MISSING"}, "web")
      end
    end
  end
end
