defmodule ConjureWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :conjure

  @session_options [
    store: :cookie,
    key: "_conjure_key",
    signing_salt: "a6656219",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: {:conjure, "priv/static"},
    gzip: false

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ConjureWeb.Router
end
