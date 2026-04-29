defmodule Bates.Middleware.Direnv do
  @behaviour Bates.Middleware

  alias Bates.ProcessInvocation

  @source_line ~S[eval "$(direnv export bash)"]

  @impl Bates.Middleware
  def apply(%ProcessInvocation{prologue: prologue} = invocation, _context) do
    %{invocation | prologue: prologue ++ [@source_line]}
  end
end
