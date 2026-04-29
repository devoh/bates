defmodule Bates.Middleware.Registry do
  @builtins %{
    "asdf" => Bates.Middleware.Asdf,
    "port" => Bates.Middleware.Port
  }

  def lookup(name) when is_binary(name) do
    case Map.fetch(all(), name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown}
    end
  end

  def lookup!(name) when is_binary(name) do
    case lookup(name) do
      {:ok, module} ->
        module

      {:error, :unknown} ->
        known = all() |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        raise "Unknown middleware: #{inspect(name)} (known: #{known})"
    end
  end

  defp all do
    extra = Application.get_env(:bates, :extra_middleware, %{})
    Map.merge(@builtins, extra)
  end
end
