import Config

config :bates, BatesWeb.Endpoint,
  url: [host: "bates.test"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BatesWeb.ErrorHTML, json: BatesWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Bates.PubSub,
  live_view: [signing_salt: "a6656219281d517f"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
