import Config

config :bates, BatesWeb.Endpoint,
  http: [port: 4080],
  secret_key_base:
    "8d92b2f472c7deb4054a5fa64b1f1d32572f9a1495cb6e7bdbd34837fa3352d1fe70201c37ded9d7a7e7f95d67780e2877e515839f46c51fbc5a87f9f000f67e",
  debug_errors: true,
  check_origin: false

config :logger, level: :debug
