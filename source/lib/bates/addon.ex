defmodule Bates.Addon do
  @callback definition() :: %{
              required(:command) => String.t(),
              optional(:middleware) => [String.t()]
            }
end
