defmodule Bates.ProcessInvocation do
  @enforce_keys [:command]
  defstruct prologue: [], environment: %{}, exports: %{}, command: nil

  @type t :: %__MODULE__{
          prologue: [String.t()],
          environment: %{String.t() => String.t()},
          exports: %{String.t() => String.t()},
          command: String.t()
        }

  def compile(%__MODULE__{prologue: [], command: command}) do
    "exec #{command}"
  end

  def compile(%__MODULE__{prologue: prologue, command: command}) do
    Enum.join(prologue ++ ["exec #{command}"], "; ")
  end
end
