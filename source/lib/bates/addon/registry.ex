defmodule Bates.Addon.Registry do
  @builtins %{}

  def lookup(name) when is_binary(name) do
    case Map.fetch(all(), name) do
      {:ok, definition} -> {:ok, normalize(name, definition)}
      :error -> {:error, :unknown}
    end
  end

  def lookup!(name) when is_binary(name) do
    case lookup(name) do
      {:ok, definition} ->
        definition

      {:error, :unknown} ->
        known = all() |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        raise "Unknown addon: #{inspect(name)} (known: #{known})"
    end
  end

  defp normalize(name, definition) do
    Map.put_new(definition, :middleware, [name])
  end

  if Mix.env() == :test do
    @extra_key :extra_addons

    def register(name, definition)
        when is_binary(name) and is_map(definition) do
      extra = Application.get_env(:bates, @extra_key, %{})
      Application.put_env(:bates, @extra_key, Map.put(extra, name, definition))
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
