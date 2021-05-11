defmodule Conjure.Config do
  @path "config.toml"

  def processes(path \\ @path) do
    with {:ok, toml} <- File.read(path),
         {:ok, config} <- Toml.decode(toml) do
      config
      |> Enum.map(&build_process/1)
      |> Enum.map(&(struct(Conjure.Process, &1)))
    end
  end

  defp build_process({name, options}) do
    for {key, value} <- Map.put(options, "name", name),
      into: %{},
      do: {String.to_existing_atom(key), value}
  end
end
