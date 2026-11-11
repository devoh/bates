defmodule BatesWeb.ServiceList do
  @moduledoc """
  The list of an app's services shown on the loading and paused pages.

  Both pages list every service in the same order: the requested
  service's dependency chain first, then the rest in their usual order.
  """
  use Phoenix.Component

  alias Bates.App
  alias BatesWeb.Lamp

  @doc """
  Returns the services of `app_name` in display order for a request to
  `service_name`, or an empty list when the app isn't running.
  """
  def fetch(app_name, service_name) do
    services = App.services(app_name)
    chain = dependency_chain(services, service_name)
    chain_names = MapSet.new(chain, & &1.name)
    chain ++ Enum.reject(services, &MapSet.member?(chain_names, &1.name))
  catch
    :exit, _ -> []
  end

  @doc "Renders services as rows with a status lamp."
  attr(:services, :list, required: true)

  def list(assigns) do
    ~H"""
    <ul class="bates-loading__chain">
      <li :for={svc <- @services} class="bates-loading__row">
        <Lamp.lamp state={Lamp.state(svc.status)} />
        <span class="bates-loading__service">{svc.name}</span>
      </li>
    </ul>
    """
  end

  # Build the ordered list of services leading up to `service_name`:
  # transitive dependencies first (in topological order), then the
  # requested service last. Cycles and missing services are tolerated
  # — App.Config rejects invalid graphs at startup, so this code only
  # has to be correct for well-formed graphs.
  defp dependency_chain(services, service_name) do
    by_name = Map.new(services, &{&1.name, &1})
    {chain, _visited} = walk(service_name, by_name, MapSet.new(), [])
    chain
  end

  defp walk(name, by_name, visited, acc) do
    cond do
      MapSet.member?(visited, name) ->
        {acc, visited}

      svc = Map.get(by_name, name) ->
        visited = MapSet.put(visited, name)

        {acc, visited} =
          Enum.reduce(svc.depends_on || [], {acc, visited}, fn dep, {a, v} ->
            walk(dep, by_name, v, a)
          end)

        {acc ++ [svc], visited}

      true ->
        {acc, visited}
    end
  end
end
