defmodule Bates.CLI.Target do
  @moduledoc false

  alias Bates.CLI.Client

  @doc """
  Resolves a command's target argument.

  `nil` and `:<service>` use the current directory's application. Returns
  `{:app, app}`, `{:service, app, service}`, `{:error, message}` when the
  current directory doesn't resolve, or `:invalid` for a malformed name.
  """
  def resolve(nil) do
    with {:ok, app} <- Client.resolve_app_by_cwd(), do: {:app, app}
  end

  def resolve(name) when is_binary(name) do
    case String.split(name, ":") do
      [app] when app != "" ->
        {:app, app}

      ["", service] when service != "" ->
        with {:ok, app} <- Client.resolve_app_by_cwd(),
             do: {:service, app, service}

      [app, service] when app != "" and service != "" ->
        {:service, app, service}

      _ ->
        :invalid
    end
  end
end
