defmodule Conjure.ProcessSupervisor do
  use DynamicSupervisor

  alias Conjure.ProcessPort

  def start_link(_) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def add(process) do
    spec = ProcessPort.child_spec(process)

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:error, {:already_started, _pid}} -> ProcessPort.updated(process)
      result -> result
    end
  end

  def remove(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
