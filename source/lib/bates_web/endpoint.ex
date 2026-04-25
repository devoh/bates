defmodule BatesWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :bates

  @session_options [
    store: :cookie,
    key: "_bates_key",
    signing_salt: "a6656219",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: {:bates, "priv/static"},
    gzip: false

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug BatesWeb.Router
end
