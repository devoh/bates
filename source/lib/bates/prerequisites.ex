defmodule Bates.Prerequisites do
  @moduledoc """
  System prerequisite checks gating `bates start`.

  Today this covers the Caddy executable being on `$PATH` and the
  presence of `/etc/resolver/test`. Caddy's CA-trust step is no longer
  a `bates start` prereq — it lives in `bates setup`.
  """

  @resolver_path "/etc/resolver/test"

  @doc """
  Verifies all `bates start` prerequisites.

  Returns `:ok` if every check passes, otherwise `{:error, reason}`
  with a user-facing message describing the first failure.
  """
  def verify do
    with :ok <- check_caddy_in_path(),
         :ok <- check_resolver_file() do
      :ok
    end
  end

  defp check_caddy_in_path do
    case System.find_executable("caddy") do
      nil ->
        {:error,
         "`caddy` not found in $PATH. Install with: brew install caddy"}

      _path ->
        :ok
    end
  end

  defp check_resolver_file do
    if File.exists?(@resolver_path) do
      :ok
    else
      {:error,
       "#{@resolver_path} not found. Run `bates setup` to create it."}
    end
  end
end
