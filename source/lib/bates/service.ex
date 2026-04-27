defmodule Bates.Service do
  @enforce_keys [:name, :command]
  defstruct name: "",
            command: "",
            port: nil,
            hostname: nil,
            middleware: []
end
