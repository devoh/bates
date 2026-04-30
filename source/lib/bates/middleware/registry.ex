defmodule Bates.Middleware.Registry do
  @builtins %{
    "asdf" => Bates.Middleware.Asdf,
    "direnv" => Bates.Middleware.Direnv,
    "port" => Bates.Middleware.Port
  }

  def lookup(name) when is_binary(name) do
    case Map.fetch(all(), name) do
      {:ok, module} -> {:ok, module}
      :error -> Bates.Addons.Registry.lookup_module(name)
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

  if Mix.env() == :test do
    @extra_key :extra_middleware

    def register(name, module) when is_binary(name) and is_atom(module) do
      extra = Application.get_env(:bates, @extra_key, %{})
      Application.put_env(:bates, @extra_key, Map.put(extra, name, module))
      :ok
    end

    def unregister(name) when is_binary(name) do
      extra = Application.get_env(:bates, @extra_key, %{})
      Application.put_env(:bates, @extra_key, Map.delete(extra, name))
      :ok
    end

    defp all do
      extra = Application.get_env(:bates, @extra_key, %{})
      Map.merge(@builtins, extra)
    end
  else
    defp all, do: @builtins
  end
end
