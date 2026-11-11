defmodule Bates.Middleware.Asdf do
  @behaviour Bates.Middleware

  alias Bates.ProcessInvocation

  @shims_line ~S[export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"]

  @impl Bates.Middleware
  def apply(%ProcessInvocation{prologue: prologue} = invocation, _context) do
    %{invocation | prologue: prologue ++ [@shims_line]}
  end
end
