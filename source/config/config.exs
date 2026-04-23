import Config

config :conjure, ConjureWeb.Endpoint,
  url: [host: "conjure.test"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ConjureWeb.ErrorHTML, json: ConjureWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Conjure.PubSub,
  live_view: [signing_salt: "a6656219281d517f"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
