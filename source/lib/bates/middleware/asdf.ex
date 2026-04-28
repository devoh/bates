defmodule Bates.Middleware.Asdf do
  @behaviour Bates.Middleware

  alias Bates.ProcessInvocation

  @source_line "source $(brew --prefix)/opt/asdf/libexec/asdf.sh"

  @impl Bates.Middleware
  def apply(%ProcessInvocation{prologue: prologue} = invocation, _context) do
    %{invocation | prologue: prologue ++ [@source_line]}
  end
end
