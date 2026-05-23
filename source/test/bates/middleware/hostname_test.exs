defmodule Bates.Middleware.HostnameTest do
  use ExUnit.Case, async: true

  alias Bates.{ProcessInvocation, Service}
  alias Bates.Middleware.Hostname

  describe "apply/2" do
    test "adds HOST to environment for the app's primary hostname" do
      invocation = %ProcessInvocation{command: "bin/rails server"}
      service = %Service{name: "web", command: "x", hostname: "myapp.test"}

      result =
        Hostname.apply(invocation, %{service: service, app_name: "myapp"})

      assert result.environment == %{"HOST" => "myapp.test"}
      assert result.exports == %{}
    end

    test "is a no-op for services whose hostname is not the app's primary" do
      invocation = %ProcessInvocation{command: "bin/vite dev"}
      service = %Service{name: "vite", command: "x", hostname: "vite.test"}

      result =
        Hostname.apply(invocation, %{service: service, app_name: "myapp"})

      assert result == invocation
    end

    test "is a no-op for services without a hostname" do
      invocation = %ProcessInvocation{command: "bin/sidekiq"}
      service = %Service{name: "worker", command: "x", hostname: nil}

      result =
        Hostname.apply(invocation, %{service: service, app_name: "myapp"})

      assert result == invocation
    end

    test "merges HOST into existing environment without touching exports" do
      invocation = %ProcessInvocation{
        environment: %{"FOO" => "bar"},
        exports: %{"PGPORT" => "5432"},
        command: "bin/rails server"
      }

      service = %Service{name: "web", command: "x", hostname: "myapp.test"}

      result =
        Hostname.apply(invocation, %{service: service, app_name: "myapp"})

      assert result.environment == %{"FOO" => "bar", "HOST" => "myapp.test"}
      assert result.exports == %{"PGPORT" => "5432"}
    end
  end

  describe "static_exports/1" do
    test "returns HOST for the app's primary hostname" do
      service = %Service{name: "web", command: "x", hostname: "myapp.test"}

      assert Hostname.static_exports(%{service: service, app_name: "myapp"}) ==
               %{"HOST" => "myapp.test"}
    end

    test "returns empty for services whose hostname is not the app's primary" do
      service = %Service{name: "vite", command: "x", hostname: "vite.test"}

      assert Hostname.static_exports(%{service: service, app_name: "myapp"}) ==
               %{}
    end

    test "returns empty for services without a hostname" do
      service = %Service{name: "worker", command: "x", hostname: nil}

      assert Hostname.static_exports(%{service: service, app_name: "myapp"}) ==
               %{}
    end
  end
end
