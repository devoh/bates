defmodule Bates.Config do
  @path "config.toml"

  def processes(path \\ @path) do
    with {:ok, toml} <- File.read(path),
         {:ok, config} <- Toml.decode(toml) do
      config
      |> Enum.map(&build_process/1)
      |> Enum.map(&struct(Bates.Process, &1))
    else
      {:error, :enoent} -> []
      {:error, _} = error -> error
    end
  end

  defp build_process({name, options}) do
    for {key, value} <- Map.put(options, "name", name),
        into: %{},
        do: {String.to_existing_atom(key), value}
  end
end
