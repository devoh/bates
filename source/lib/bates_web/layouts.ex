defmodule BatesWeb.Layouts do
  use Phoenix.Component

  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  embed_templates "layouts/*"
end
