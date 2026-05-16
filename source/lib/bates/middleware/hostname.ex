defmodule Bates.Middleware.Hostname do
  @behaviour Bates.Middleware

  alias Bates.ProcessInvocation

  @impl Bates.Middleware
  def apply(%ProcessInvocation{} = invocation, %{
        service: %{hostname: hostname},
        app_name: app_name
      })
      when is_binary(hostname) and is_binary(app_name) do
    if hostname == "#{app_name}.test" do
      %{
        invocation
        | environment: Map.put(invocation.environment, "HOST", hostname),
          exports: Map.put(invocation.exports, "HOST", hostname)
      }
    else
      invocation
    end
  end

  def apply(%ProcessInvocation{} = invocation, _context), do: invocation
end
