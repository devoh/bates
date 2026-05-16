defmodule Bates.Middleware.HostnameTest do
  use ExUnit.Case, async: true

  alias Bates.{ProcessInvocation, Service}
  alias Bates.Middleware.Hostname

  test "adds HOST to environment and exports for the app's primary hostname" do
    invocation = %ProcessInvocation{command: "bin/rails server"}
    service = %Service{name: "web", command: "x", hostname: "myapp.test"}

    result = Hostname.apply(invocation, %{service: service, app_name: "myapp"})

    assert result.environment == %{"HOST" => "myapp.test"}
    assert result.exports == %{"HOST" => "myapp.test"}
  end

  test "is a no-op for services whose hostname is not the app's primary" do
    invocation = %ProcessInvocation{command: "bin/vite dev"}
    service = %Service{name: "vite", command: "x", hostname: "vite.test"}

    result = Hostname.apply(invocation, %{service: service, app_name: "myapp"})

    assert result == invocation
  end

  test "is a no-op for services without a hostname" do
    invocation = %ProcessInvocation{command: "bin/sidekiq"}
    service = %Service{name: "worker", command: "x", hostname: nil}

    result = Hostname.apply(invocation, %{service: service, app_name: "myapp"})

    assert result == invocation
  end

  test "merges HOST into existing environment and exports" do
    invocation = %ProcessInvocation{
      environment: %{"FOO" => "bar"},
      exports: %{"PGPORT" => "5432"},
      command: "bin/rails server"
    }

    service = %Service{name: "web", command: "x", hostname: "myapp.test"}

    result = Hostname.apply(invocation, %{service: service, app_name: "myapp"})

    assert result.environment == %{"FOO" => "bar", "HOST" => "myapp.test"}
    assert result.exports == %{"PGPORT" => "5432", "HOST" => "myapp.test"}
  end
end
