defmodule Bates.Service do
  @enforce_keys [:name, :command]

  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          port: :auto | non_neg_integer() | nil,
          hostname: String.t() | nil,
          middleware: [String.t()],
          depends_on: [String.t()],
          addon?: boolean()
        }

  defstruct name: "",
            command: "",
            port: nil,
            hostname: nil,
            middleware: [],
            depends_on: [],
            addon?: false
end
