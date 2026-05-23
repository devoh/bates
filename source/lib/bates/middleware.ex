defmodule Bates.Middleware do
  alias Bates.ProcessInvocation

  @callback apply(ProcessInvocation.t(), map()) :: ProcessInvocation.t()

  @doc """
  Returns exports that are derivable from configuration alone, without
  running the service. Defaults to `%{}` for middleware that has no
  config-derived exports.

  Used by `bates env` to surface stable values (e.g., the app's primary
  hostname) regardless of whether any process is currently running.
  """
  @callback static_exports(map()) :: %{String.t() => String.t()}

  @optional_callbacks static_exports: 1

  def apply_pipeline(%ProcessInvocation{} = invocation, modules, context)
      when is_list(modules) and is_map(context) do
    Enum.reduce(modules, invocation, fn module, acc ->
      module.apply(acc, context)
    end)
  end

  def collect_static_exports(modules, context)
      when is_list(modules) and is_map(context) do
    Enum.reduce(modules, %{}, fn module, acc ->
      # Load the module before probing for the callback — `function_exported?/3`
      # only inspects loaded modules and would otherwise silently skip
      # middleware that legitimately implements `static_exports/1`.
      Code.ensure_loaded(module)

      if function_exported?(module, :static_exports, 1) do
        Map.merge(acc, module.static_exports(context))
      else
        acc
      end
    end)
  end
end
