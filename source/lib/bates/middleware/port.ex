defmodule Bates.Middleware.Port do
  @behaviour Bates.Middleware

  alias Bates.ProcessInvocation

  @impl Bates.Middleware
  def apply(%ProcessInvocation{} = invocation, %{assigned_port: port})
      when is_integer(port) do
    %{
      invocation
      | environment: Map.put(invocation.environment, "PORT", to_string(port))
    }
  end

  def apply(%ProcessInvocation{} = invocation, _context), do: invocation
end
