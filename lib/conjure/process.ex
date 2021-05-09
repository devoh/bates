defmodule Conjure.Process do
  @enforce_keys [:name, :command, :dir]
  defstruct [
    name: "",
    port: 0,
    command: "",
    dir: "",
    env: %{}
  ]
end
