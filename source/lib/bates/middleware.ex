defmodule Bates.Middleware do
  alias Bates.ProcessInvocation

  @callback apply(ProcessInvocation.t(), map()) :: ProcessInvocation.t()

  def apply_pipeline(%ProcessInvocation{} = invocation, modules, context)
      when is_list(modules) and is_map(context) do
    Enum.reduce(modules, invocation, fn module, acc ->
      module.apply(acc, context)
    end)
  end
end
