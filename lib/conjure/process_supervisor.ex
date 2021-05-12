defmodule Conjure.ProcessSupervisor do
  use DynamicSupervisor

  alias Conjure.Process

  # public API

  def start_link(_) do
    case DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__) do
      {:ok, _pid} = ok ->
        Task.start(&load_processes/0)
        ok

      other ->
        other
    end
  end

  def status do
    for name <- process_names(),
        into: %{},
        do: {name, Process.status(name)}
  end

  # callbacks

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # helpers

  defp load_processes do
    Conjure.Config.processes() |> Enum.each(&start_child/1)
  end

  defp process_names do
    Registry.select(Conjure.ProcessRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp start_child(process) do
    spec = Process.child_spec(process)

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end
end
