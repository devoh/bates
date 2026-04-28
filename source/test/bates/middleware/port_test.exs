defmodule Bates.Middleware.PortTest do
  use ExUnit.Case, async: true

  alias Bates.ProcessInvocation
  alias Bates.Middleware.Port

  test "adds PORT to environment when :assigned_port is set" do
    invocation = %ProcessInvocation{command: "bin/rails server"}

    result = Port.apply(invocation, %{assigned_port: 5000})

    assert result.environment == %{"PORT" => "5000"}
  end

  test "merges PORT into existing environment" do
    invocation = %ProcessInvocation{
      environment: %{"FOO" => "bar"},
      command: "bin/rails server"
    }

    result = Port.apply(invocation, %{assigned_port: 5000})

    assert result.environment == %{"FOO" => "bar", "PORT" => "5000"}
  end

  test "returns the invocation unchanged when :assigned_port is missing" do
    invocation = %ProcessInvocation{command: "bin/rails server"}

    assert Port.apply(invocation, %{}) == invocation
  end

  test "returns the invocation unchanged when :assigned_port is nil" do
    invocation = %ProcessInvocation{command: "bin/rails server"}

    assert Port.apply(invocation, %{assigned_port: nil}) == invocation
  end
end
