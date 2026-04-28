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

defmodule Bates.Middleware.Registry do
  @middleware %{
    "asdf" => Bates.Middleware.Asdf,
    "port" => Bates.Middleware.Port
  }

  def lookup(name) when is_binary(name) do
    case Map.fetch(@middleware, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown}
    end
  end

  def lookup!(name) when is_binary(name) do
    case lookup(name) do
      {:ok, module} -> module
      {:error, :unknown} -> raise "Unknown middleware: #{inspect(name)}"
    end
  end
end
