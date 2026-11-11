defmodule Bates.DependencyGraphTest do
  use ExUnit.Case, async: true

  alias Bates.DependencyGraph

  # web -> api -> db, web -> cache, worker -> db
  @graph DependencyGraph.new(%{
           "web" => ["api", "cache"],
           "api" => ["db"],
           "worker" => ["db"],
           "cache" => [],
           "db" => []
         })

  describe "stop_order/1" do
    test "lists every service once, each dependent before its dependencies" do
      order = DependencyGraph.stop_order(@graph)

      assert Enum.sort(order) == ~w(api cache db web worker)

      for {dependent, dependency} <- [
            {"web", "api"},
            {"web", "cache"},
            {"api", "db"},
            {"worker", "db"}
          ] do
        assert index(order, dependent) < index(order, dependency)
      end
    end

    test "returns an empty list for an empty graph" do
      assert DependencyGraph.stop_order(DependencyGraph.new(%{})) == []
    end
  end

  describe "requirements/2" do
    test "includes the service and its transitive dependencies" do
      assert DependencyGraph.requirements(@graph, "web") ==
               MapSet.new(~w(web api cache db))
    end

    test "is just the service when it has no dependencies" do
      assert DependencyGraph.requirements(@graph, "db") == MapSet.new(["db"])
    end
  end

  describe "dependents/2" do
    test "includes the service and everything transitively depending on it" do
      assert DependencyGraph.dependents(@graph, "db") ==
               MapSet.new(~w(db api worker web))
    end

    test "is just the service when nothing depends on it" do
      assert DependencyGraph.dependents(@graph, "web") == MapSet.new(["web"])
    end
  end

  defp index(list, item), do: Enum.find_index(list, &(&1 == item))
end
