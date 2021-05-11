defmodule Conjure.ProcessSupervisor do
  use DynamicSupervisor

  alias Conjure.ProcessExec

  def start_link(_) do
    case DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__) do
      {:ok, _pid} = ok ->
        Task.start(&load_processes/0)
        ok
      other -> other
    end
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def add(process) do
    spec = ProcessExec.child_spec(process)

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  defp load_processes do
    Conjure.Config.processes() |> Enum.each(&add/1)
  end
end
