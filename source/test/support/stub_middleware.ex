defmodule Bates.TestSupport.ExportProducer do
  @moduledoc """
  Test middleware that publishes a service's `exports` map.

  Tests register the exports each service should publish via the
  `:bates` application env under `:export_producer_exports`, keyed by
  service name:

      Application.put_env(:bates, :export_producer_exports, %{
        "vite" => %{"VITE_PORT" => "5173"}
      })
  """

  @behaviour Bates.Middleware

  @impl true
  def apply(invocation, %{service: %{name: name}}) do
    exports_by_service =
      Application.get_env(:bates, :export_producer_exports, %{})

    exports = Map.get(exports_by_service, name, %{})
    %{invocation | exports: Map.merge(invocation.exports, exports)}
  end
end

defmodule Bates.TestSupport.EnvironmentRecorder do
  @moduledoc """
  Test middleware that snapshots the inbound `environment` map.

  Tests read the captured environment via the `:bates` application env
  under `:environment_recorder`, keyed by service name. Use this to
  verify that exports from upstream services were merged into a
  consumer's seeded environment.
  """

  @behaviour Bates.Middleware

  @impl true
  def apply(invocation, %{service: %{name: name}}) do
    captured =
      Application.get_env(:bates, :environment_recorder, %{})
      |> Map.put(name, invocation.environment)

    Application.put_env(:bates, :environment_recorder, captured)
    invocation
  end
end

defmodule Bates.TestSupport.EnvironmentOverride do
  @moduledoc """
  Test middleware that overlays additional environment entries on top
  of whatever was already seeded.

  Tests register the override map via the `:bates` application env
  under `:environment_override`, keyed by service name. Used to verify
  that consumer middleware can win against the seed.
  """

  @behaviour Bates.Middleware

  @impl true
  def apply(invocation, %{service: %{name: name}}) do
    overrides_by_service =
      Application.get_env(:bates, :environment_override, %{})

    overrides = Map.get(overrides_by_service, name, %{})

    %{
      invocation
      | environment: Map.merge(invocation.environment, overrides)
    }
  end
end
