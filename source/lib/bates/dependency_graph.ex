defmodule Bates.DependencyGraph do
  @moduledoc """
  The services of one application and what each `depends_on`. Answers
  the ordering and closure questions needed to start and stop them.

  Assumes the graph is acyclic and that every dependency is itself a
  service, both of which `Bates.Config` validates at load time.
  """

  @enforce_keys [:dependencies, :dependents]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            dependencies: %{String.t() => [String.t()]},
            dependents: %{String.t() => [String.t()]}
          }

  @doc "Builds a graph from a map of service name to its dependencies."
  @spec new(%{String.t() => [String.t()]}) :: t
  def new(dependencies) when is_map(dependencies) do
    empty = Map.new(dependencies, fn {name, _} -> {name, []} end)

    dependents =
      for {name, names} <- dependencies, dependency <- names, reduce: empty do
        acc -> Map.update!(acc, dependency, &[name | &1])
      end

    %__MODULE__{dependencies: dependencies, dependents: dependents}
  end

  @doc "Returns every service with each dependent before its dependencies."
  @spec stop_order(t) :: [String.t()]
  def stop_order(%__MODULE__{dependencies: dependencies}) do
    {order, _visited} =
      dependencies
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce({[], MapSet.new()}, &visit(&1, dependencies, &2))

    order
  end

  @doc "Returns `name` and everything it transitively depends on."
  @spec requirements(t, String.t()) :: MapSet.t(String.t())
  def requirements(%__MODULE__{dependencies: dependencies}, name),
    do: reachable([name], dependencies, MapSet.new())

  @doc "Returns `name` and everything that transitively depends on it."
  @spec dependents(t, String.t()) :: MapSet.t(String.t())
  def dependents(%__MODULE__{dependents: dependents}, name),
    do: reachable([name], dependents, MapSet.new())

  # Depth-first, prepending each service after its dependencies so the
  # result lists dependents first.
  defp visit(name, dependencies, {order, visited}) do
    if MapSet.member?(visited, name) do
      {order, visited}
    else
      {order, visited} =
        dependencies
        |> Map.fetch!(name)
        |> Enum.reduce(
          {order, MapSet.put(visited, name)},
          &visit(&1, dependencies, &2)
        )

      {[name | order], visited}
    end
  end

  defp reachable([], _edges, seen), do: seen

  defp reachable([name | rest], edges, seen) do
    if MapSet.member?(seen, name) do
      reachable(rest, edges, seen)
    else
      reachable(Map.fetch!(edges, name) ++ rest, edges, MapSet.put(seen, name))
    end
  end
end
