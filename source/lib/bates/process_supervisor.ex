defmodule Bates.ProcessSupervisor do
  use DynamicSupervisor

  alias Bates.App

  # Public API

  def start_link(_) do
    case DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__) do
      {:ok, _pid} = ok ->
        Task.start(&load_applications/0)
        ok

      other ->
        other
    end
  end

  def app_names do
    Registry.select(Bates.ProcessRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def app_pid(name) do
    case Registry.lookup(Bates.ProcessRegistry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def hostname_lookup do
    for name <- app_names(),
        service <- App.services(name),
        service.hostname != nil,
        into: %{} do
      {service.hostname, {name, service.name}}
    end
  end

  def status do
    for name <- app_names(),
        into: %{},
        do: {name, App.status(name)}
  end

  # Callbacks

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # Helpers

  defp load_applications do
    case Bates.Config.applications() do
      {:error, reason} ->
        raise "Bates configuration error: #{inspect(reason)}"

      applications when is_list(applications) ->
        Enum.each(applications, &start_child/1)
    end
  end

  defp start_child(config) do
    spec = App.child_spec(config)

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end
end
